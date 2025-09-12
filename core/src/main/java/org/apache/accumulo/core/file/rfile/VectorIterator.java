/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.accumulo.core.file.rfile;

import static java.util.Objects.requireNonNull;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import org.apache.accumulo.access.AccessEvaluator;
import org.apache.accumulo.access.AccessExpression;
import org.apache.accumulo.access.Authorizations;
import org.apache.accumulo.core.data.Key;
import org.apache.accumulo.core.data.Range;
import org.apache.accumulo.core.data.Value;
import org.apache.accumulo.core.data.ValueType;
import org.apache.accumulo.core.iterators.IteratorEnvironment;
import org.apache.accumulo.core.iterators.IteratorUtil.IteratorScope;
import org.apache.accumulo.core.iterators.SortedKeyValueIterator;

/**
 * Iterator for efficient vector similarity searches in RFile. Supports cosine similarity and dot
 * product operations with coarse filtering using block centroids and fine-grained similarity
 * computation.
 */
public class VectorIterator implements SortedKeyValueIterator<Key,Value> {

  public static final String QUERY_VECTOR_OPTION = "queryVector";
  public static final String SIMILARITY_TYPE_OPTION = "similarityType";
  public static final String TOP_K_OPTION = "topK";
  public static final String THRESHOLD_OPTION = "threshold";
  public static final String USE_COMPRESSION_OPTION = "useCompression";
  public static final String MAX_CANDIDATE_BLOCKS_OPTION = "maxCandidateBlocks";
  public static final String AUTHORIZATIONS_OPTION = "authorizations";

  public enum SimilarityType {
    COSINE, DOT_PRODUCT
  }

  /**
   * Result entry containing a key-value pair with its similarity score.
   */
  public static class SimilarityResult {
    private final Key key;
    private final Value value;
    private final float similarity;

    public SimilarityResult(Key key, Value value, float similarity) {
      this.key = key;
      this.value = value;
      this.similarity = similarity;
    }

    public Key getKey() {
      return key;
    }

    public Value getValue() {
      return value;
    }

    public float getSimilarity() {
      return similarity;
    }
  }

  private SortedKeyValueIterator<Key,Value> source;
  private VectorIndex vectorIndex;
  private VectorIndexFooter indexFooter;
  private VectorBuffer vectorBuffer;
  private AccessEvaluator visibilityEvaluator;

  private float[] queryVector;
  private SimilarityType similarityType = SimilarityType.COSINE;
  private int topK = 10;
  private float threshold = 0.0f;
  private boolean useCompression = false;
  private int maxCandidateBlocks = 50; // Limit blocks to search for performance

  private List<SimilarityResult> results;
  private int currentResultIndex;

  @Override
  public void init(SortedKeyValueIterator<Key,Value> source, Map<String,String> options,
      IteratorEnvironment env) throws IOException {
    this.source = source;

    // Initialize vector buffer for batching/staging
    this.vectorBuffer = new VectorBuffer();

    // Parse options
    if (options.containsKey(QUERY_VECTOR_OPTION)) {
      queryVector = parseVectorFromString(options.get(QUERY_VECTOR_OPTION));
    }

    if (options.containsKey(SIMILARITY_TYPE_OPTION)) {
      similarityType = SimilarityType.valueOf(options.get(SIMILARITY_TYPE_OPTION).toUpperCase());
    }

    if (options.containsKey(TOP_K_OPTION)) {
      topK = Integer.parseInt(options.get(TOP_K_OPTION));
    }

    if (options.containsKey(THRESHOLD_OPTION)) {
      threshold = Float.parseFloat(options.get(THRESHOLD_OPTION));
    }

    if (options.containsKey(USE_COMPRESSION_OPTION)) {
      useCompression = Boolean.parseBoolean(options.get(USE_COMPRESSION_OPTION));
    }

    if (options.containsKey(MAX_CANDIDATE_BLOCKS_OPTION)) {
      maxCandidateBlocks = Integer.parseInt(options.get(MAX_CANDIDATE_BLOCKS_OPTION));
    }

    // Initialize visibility evaluator with authorizations
    if (options.containsKey(AUTHORIZATIONS_OPTION)) {
      String authString = options.get(AUTHORIZATIONS_OPTION);
      Authorizations authorizations =
          Authorizations.of(Arrays.stream(authString.split(",")).collect(Collectors.toSet()));
      visibilityEvaluator = AccessEvaluator.of(authorizations);
    } else {
      // Initialize visibility evaluator if we have authorizations from the environment
      if (env.getIteratorScope() != IteratorScope.scan) {
        // For non-scan contexts, we may not have authorizations available
        visibilityEvaluator = null;
      } else {
        // Try to get authorizations from the environment
        // Note: This would need to be adapted based on how authorizations are provided
        visibilityEvaluator = null; // Placeholder - would be initialized with proper authorizations
      }
    }

    results = new ArrayList<>();
    currentResultIndex = 0;
  }

  @Override
  public boolean hasTop() {
    return currentResultIndex < results.size();
  }

  @Override
  public void next() throws IOException {
    currentResultIndex++;
  }

  @Override
  public void seek(Range range,
      Collection<org.apache.accumulo.core.data.ByteSequence> columnFamilies, boolean inclusive)
      throws IOException {
    if (queryVector == null) {
      throw new IllegalStateException("Query vector not set");
    }

    results.clear();
    currentResultIndex = 0;

    source.seek(range, columnFamilies, inclusive);
    performVectorSearch();

    // Sort results by similarity (descending)
    results.sort(Comparator.<SimilarityResult>comparingDouble(r -> r.similarity).reversed());

    // Limit to top K results
    if (results.size() > topK) {
      results = results.subList(0, topK);
    }
  }

  @Override
  public Key getTopKey() {
    if (!hasTop()) {
      return null;
    }
    return results.get(currentResultIndex).getKey();
  }

  @Override
  public Value getTopValue() {
    if (!hasTop()) {
      return null;
    }
    return results.get(currentResultIndex).getValue();
  }

  @Override
  public SortedKeyValueIterator<Key,Value> deepCopy(IteratorEnvironment env) {
    VectorIterator copy = new VectorIterator();
    try {
      copy.init(source.deepCopy(env), getOptions(), env);
    } catch (IOException e) {
      throw new RuntimeException("Failed to deep copy VectorIterator", e);
    }
    return copy;
  }

  private Map<String,String> getOptions() {
    Map<String,String> options = new java.util.HashMap<>();
    if (queryVector != null) {
      options.put(QUERY_VECTOR_OPTION, vectorToString(queryVector));
    }
    options.put(SIMILARITY_TYPE_OPTION, similarityType.toString());
    options.put(TOP_K_OPTION, String.valueOf(topK));
    options.put(THRESHOLD_OPTION, String.valueOf(threshold));
    return options;
  }

  /**
   * Performs the vector similarity search using block-level coarse filtering followed by
   * fine-grained similarity computation.
   */
  private void performVectorSearch() throws IOException {
    // Use advanced indexing if available for candidate block selection
    List<Integer> candidateBlockIndices = getCandidateBlockIndices();

    if (candidateBlockIndices.isEmpty()) {
      // Fall back to scanning all data if no index available
      scanAllData();
    } else {
      // Use efficient batch processing with vector buffer
      processCandidateBlocks(candidateBlockIndices);
    }
  }

  private List<Integer> getCandidateBlockIndices() {
    if (indexFooter != null && queryVector != null) {
      // Use advanced indexing for candidate selection
      return indexFooter.findCandidateBlocks(queryVector, maxCandidateBlocks);
    } else if (vectorIndex != null && !vectorIndex.getBlocks().isEmpty()) {
      // Fall back to basic centroid-based filtering
      return getBasicCandidateBlocks();
    }

    return new ArrayList<>(); // No indexing available
  }

  private List<Integer> getBasicCandidateBlocks() {
    List<Integer> candidates = new ArrayList<>();
    List<VectorIndex.VectorBlockMetadata> blocks = vectorIndex.getBlocks();

    for (int i = 0; i < blocks.size(); i++) {
      VectorIndex.VectorBlockMetadata block = blocks.get(i);

      // Check visibility permissions for block
      if (!isBlockVisibilityAllowed(block)) {
        continue;
      }

      float centroidSimilarity = computeSimilarity(queryVector, block.getCentroid());
      // More lenient threshold for coarse filtering
      if (centroidSimilarity >= threshold * 0.5f) {
        candidates.add(i);
      }
    }

    return candidates;
  }

  private void processCandidateBlocks(List<Integer> candidateBlockIndices) throws IOException {
    // Load candidate blocks into vector buffer for efficient processing
    List<VectorIndex.VectorBlockMetadata> blocks = vectorIndex.getBlocks();

    for (Integer blockIdx : candidateBlockIndices) {
      if (blockIdx < blocks.size()) {
        VectorIndex.VectorBlockMetadata metadata = blocks.get(blockIdx);

        // Load block vectors (this would normally read from disk)
        List<VectorBuffer.VectorBlock.VectorEntry> blockVectors = loadBlockVectors(metadata);

        // Stage in vector buffer
        vectorBuffer.loadBlock(metadata.getBlockOffset(), metadata, blockVectors);
      }
    }

    // Perform parallel similarity computation using vector buffer
    List<SimilarityResult> bufferResults =
        vectorBuffer.computeSimilarities(queryVector, similarityType, topK, threshold);

    // Filter results based on visibility
    for (SimilarityResult result : bufferResults) {
      if (isVisibilityAllowed(result.getKey())) {
        results.add(result);
      }
    }

    // Clear buffer to free memory
    vectorBuffer.clear();
  }

  private List<VectorIndex.VectorBlockMetadata> getCandidateBlocks() {
    if (vectorIndex == null || vectorIndex.getBlocks().isEmpty()) {
      return Collections.emptyList();
    }

    // Compute similarity with block centroids for coarse filtering
    List<VectorIndex.VectorBlockMetadata> candidates = new ArrayList<>();
    for (VectorIndex.VectorBlockMetadata block : vectorIndex.getBlocks()) {
      float centroidSimilarity = computeSimilarity(queryVector, block.getCentroid());
      // Simple threshold-based filtering - could be made more sophisticated
      if (centroidSimilarity >= threshold * 0.5f) { // More lenient threshold for coarse filtering
        candidates.add(block);
      }
    }

    return candidates;
  }

  private void scanAllData() throws IOException {
    while (source.hasTop()) {
      Key key = source.getTopKey();
      Value value = source.getTopValue();

      if (isVisibilityAllowed(key) && isVectorValue(value)) {
        float similarity = computeSimilarity(queryVector, value.asVector());
        if (similarity >= threshold) {
          results.add(new SimilarityResult(new Key(key), new Value(value), similarity));
        }
      }

      source.next();
    }
  }

  private void scanCandidateBlocks(List<VectorIndex.VectorBlockMetadata> candidateBlocks)
      throws IOException {
    // For now, fall back to scanning all data
    // In a full implementation, this would seek to specific block ranges
    scanAllData();
  }

  private boolean isVisibilityAllowed(Key key) {
    if (visibilityEvaluator == null) {
      return true; // No visibility restrictions
    }

    AccessExpression expression =
        AccessExpression.parse(key.getColumnVisibilityData().getBackingArray());
    try {
      return visibilityEvaluator.canAccess(expression);
    } catch (Exception e) {
      return false; // Deny access on evaluation errors
    }
  }

  /**
   * Checks if a vector block's visibility allows access.
   */
  private boolean isBlockVisibilityAllowed(VectorIndex.VectorBlockMetadata block) {
    if (visibilityEvaluator == null || block.getVisibility().length == 0) {
      return true; // No visibility restrictions
    }

    AccessExpression expression = AccessExpression.parse(block.getVisibility());
    try {
      return visibilityEvaluator.canAccess(expression);
    } catch (Exception e) {
      return false; // Deny access on evaluation errors
    }
  }

  /**
   * Loads vector entries from a block (simulated - would normally read from disk).
   */
  private List<VectorBuffer.VectorBlock.VectorEntry>
      loadBlockVectors(VectorIndex.VectorBlockMetadata metadata) throws IOException {

    List<VectorBuffer.VectorBlock.VectorEntry> entries = new ArrayList<>();

    // In a real implementation, this would seek to the block offset and read vectors
    // For now, simulate by scanning the current source data
    long currentPos = 0;
    source.seek(new Range(), Collections.emptyList(), false);

    while (source.hasTop() && currentPos < metadata.getBlockOffset() + metadata.getBlockSize()) {
      Key key = source.getTopKey();
      Value value = source.getTopValue();

      if (isVectorValue(value)) {
        float[] vector;
        if (metadata.isCompressed()) {
          // Decompress vector if needed
          vector = useCompression ? value.asCompressedVector() : value.asVector();
        } else {
          vector = value.asVector();
        }

        byte[] visibility = key.getColumnVisibility().getBytes();
        entries.add(new VectorBuffer.VectorBlock.VectorEntry(key, vector, visibility));

        if (entries.size() >= metadata.getVectorCount()) {
          break; // Loaded expected number of vectors
        }
      }

      source.next();
      currentPos++; // Simplified position tracking
    }

    return entries;
  }

  private boolean isVectorValue(Value value) {
    return value.getValueType() == ValueType.VECTOR_FLOAT32;
  }

  /**
   * Computes similarity between two vectors based on the configured similarity type.
   */
  private float computeSimilarity(float[] vector1, float[] vector2) {
    requireNonNull(vector1, "Vector1 cannot be null");
    requireNonNull(vector2, "Vector2 cannot be null");

    if (vector1.length != vector2.length) {
      throw new IllegalArgumentException("Vectors must have same dimension");
    }

    switch (similarityType) {
      case COSINE:
        return computeCosineSimilarity(vector1, vector2);
      case DOT_PRODUCT:
        return computeDotProduct(vector1, vector2);
      default:
        throw new IllegalArgumentException("Unknown similarity type: " + similarityType);
    }
  }

  private float computeCosineSimilarity(float[] vector1, float[] vector2) {
    float dotProduct = 0.0f;
    float norm1 = 0.0f;
    float norm2 = 0.0f;

    for (int i = 0; i < vector1.length; i++) {
      dotProduct += vector1[i] * vector2[i];
      norm1 += vector1[i] * vector1[i];
      norm2 += vector2[i] * vector2[i];
    }

    if (norm1 == 0.0f || norm2 == 0.0f) {
      return 0.0f; // Handle zero vectors
    }

    return dotProduct / (float) (Math.sqrt(norm1) * Math.sqrt(norm2));
  }

  private float computeDotProduct(float[] vector1, float[] vector2) {
    float dotProduct = 0.0f;
    for (int i = 0; i < vector1.length; i++) {
      dotProduct += vector1[i] * vector2[i];
    }
    return dotProduct;
  }

  private float[] parseVectorFromString(String vectorStr) {
    // Simple comma-separated format: "1.0,2.0,3.0"
    String[] parts = vectorStr.split(",");
    float[] vector = new float[parts.length];
    for (int i = 0; i < parts.length; i++) {
      vector[i] = Float.parseFloat(parts[i].trim());
    }
    return vector;
  }

  private String vectorToString(float[] vector) {
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < vector.length; i++) {
      if (i > 0) {
        sb.append(",");
      }
      sb.append(vector[i]);
    }
    return sb.toString();
  }

  /**
   * Sets the vector index for this iterator.
   *
   * @param vectorIndex the vector index containing block metadata
   */
  public void setVectorIndex(VectorIndex vectorIndex) {
    this.vectorIndex = vectorIndex;
  }

}
