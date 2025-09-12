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

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.stream.Collectors;

import org.apache.accumulo.core.data.Key;
import org.apache.accumulo.core.data.Value;

/**
 * Memory staging buffer for efficient batch processing of vector blocks.
 * Provides parallel similarity computation and memory management for vector search operations.
 */
public class VectorBuffer {
  
  private final int maxMemoryMB;
  private final int maxConcurrency;
  private final ConcurrentHashMap<Long, VectorBlock> loadedBlocks;
  private final ExecutorService executorService;
  private volatile long currentMemoryUsage;
  
  /**
   * Cached vector block in memory with decompressed vectors for fast similarity computation.
   */
  public static class VectorBlock {
    private final VectorIndex.VectorBlockMetadata metadata;
    private final List<VectorEntry> vectors;
    private final long memoryFootprint;
    
    public static class VectorEntry {
      private final Key key;
      private final float[] vector;
      private final byte[] visibility;
      
      public VectorEntry(Key key, float[] vector, byte[] visibility) {
        this.key = key;
        this.vector = vector;
        this.visibility = visibility;
      }
      
      public Key getKey() { return key; }
      public float[] getVector() { return vector; }
      public byte[] getVisibility() { return visibility; }
    }
    
    public VectorBlock(VectorIndex.VectorBlockMetadata metadata, List<VectorEntry> vectors) {
      this.metadata = metadata;
      this.vectors = vectors;
      // Estimate memory footprint: vectors + keys + metadata
      long vectorMemory = vectors.size() * (vectors.isEmpty() ? 0 : vectors.get(0).getVector().length * 4L);
      long keyMemory = vectors.size() * 100L; // Rough estimate for Key objects
      this.memoryFootprint = vectorMemory + keyMemory + 1024L; // Plus metadata overhead
    }
    
    public VectorIndex.VectorBlockMetadata getMetadata() { return metadata; }
    public List<VectorEntry> getVectors() { return vectors; }
    public long getMemoryFootprint() { return memoryFootprint; }
  }
  
  public VectorBuffer(int maxMemoryMB, int maxConcurrency) {
    this.maxMemoryMB = maxMemoryMB;
    this.maxConcurrency = maxConcurrency;
    this.loadedBlocks = new ConcurrentHashMap<>();
    this.executorService = Executors.newFixedThreadPool(maxConcurrency);
    this.currentMemoryUsage = 0;
  }
  
  /**
   * Default constructor with reasonable defaults.
   */
  public VectorBuffer() {
    this(512, Runtime.getRuntime().availableProcessors()); // 512MB, CPU cores
  }
  
  /**
   * Loads a vector block into memory, decompressing if necessary.
   * Implements LRU eviction when memory limit is exceeded.
   * 
   * @param blockOffset the block offset to use as key
   * @param metadata the block metadata
   * @param vectors the vector entries in this block
   * @return true if block was loaded, false if already present
   */
  public synchronized boolean loadBlock(long blockOffset, VectorIndex.VectorBlockMetadata metadata, 
                                       List<VectorBlock.VectorEntry> vectors) {
    if (loadedBlocks.containsKey(blockOffset)) {
      return false; // Already loaded
    }
    
    VectorBlock block = new VectorBlock(metadata, vectors);
    long requiredMemory = block.getMemoryFootprint();
    
    // Evict blocks if necessary to make room
    while (currentMemoryUsage + requiredMemory > maxMemoryMB * 1024L * 1024L && !loadedBlocks.isEmpty()) {
      evictLeastRecentlyUsedBlock();
    }
    
    loadedBlocks.put(blockOffset, block);
    currentMemoryUsage += requiredMemory;
    return true;
  }
  
  /**
   * Gets a loaded vector block.
   * 
   * @param blockOffset the block offset
   * @return the vector block or null if not loaded
   */
  public VectorBlock getBlock(long blockOffset) {
    return loadedBlocks.get(blockOffset);
  }
  
  /**
   * Performs parallel similarity computation across all loaded blocks.
   * 
   * @param queryVector the query vector
   * @param similarityType the similarity metric to use
   * @param topK maximum number of results to return
   * @param threshold minimum similarity threshold
   * @return list of similarity results sorted by similarity score
   */
  public List<VectorIterator.SimilarityResult> computeSimilarities(
      float[] queryVector, 
      VectorIterator.SimilarityType similarityType,
      int topK, 
      float threshold) {
    
    if (loadedBlocks.isEmpty()) {
      return new ArrayList<>();
    }
    
    // Submit parallel computation tasks
    List<Future<List<VectorIterator.SimilarityResult>>> futures = new ArrayList<>();
    
    for (VectorBlock block : loadedBlocks.values()) {
      Future<List<VectorIterator.SimilarityResult>> future = executorService.submit(() -> 
        computeBlockSimilarities(block, queryVector, similarityType, threshold)
      );
      futures.add(future);
    }
    
    // Collect results from all blocks
    List<VectorIterator.SimilarityResult> allResults = new ArrayList<>();
    for (Future<List<VectorIterator.SimilarityResult>> future : futures) {
      try {
        allResults.addAll(future.get());
      } catch (Exception e) {
        // Log error and continue with other blocks
        System.err.println("Error computing block similarities: " + e.getMessage());
      }
    }
    
    // Sort by similarity and return top-K
    return allResults.stream()
        .sorted((a, b) -> Float.compare(b.getSimilarity(), a.getSimilarity()))
        .limit(topK)
        .collect(Collectors.toList());
  }
  
  private List<VectorIterator.SimilarityResult> computeBlockSimilarities(
      VectorBlock block, 
      float[] queryVector, 
      VectorIterator.SimilarityType similarityType,
      float threshold) {
    
    List<VectorIterator.SimilarityResult> results = new ArrayList<>();
    
    for (VectorBlock.VectorEntry entry : block.getVectors()) {
      float similarity = computeSimilarity(queryVector, entry.getVector(), similarityType);
      
      if (similarity >= threshold) {
        Value vectorValue = Value.newVector(entry.getVector());
        results.add(new VectorIterator.SimilarityResult(entry.getKey(), vectorValue, similarity));
      }
    }
    
    return results;
  }
  
  private float computeSimilarity(float[] query, float[] vector, VectorIterator.SimilarityType type) {
    if (query.length != vector.length) {
      throw new IllegalArgumentException("Vector dimensions must match");
    }
    
    switch (type) {
      case COSINE:
        return cosineSimilarity(query, vector);
      case DOT_PRODUCT:
        return dotProduct(query, vector);
      default:
        throw new IllegalArgumentException("Unknown similarity type: " + type);
    }
  }
  
  private float cosineSimilarity(float[] a, float[] b) {
    float dotProduct = 0.0f;
    float normA = 0.0f;
    float normB = 0.0f;
    
    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    
    if (normA == 0.0f || normB == 0.0f) {
      return 0.0f;
    }
    
    return dotProduct / (float) (Math.sqrt(normA) * Math.sqrt(normB));
  }
  
  private float dotProduct(float[] a, float[] b) {
    float result = 0.0f;
    for (int i = 0; i < a.length; i++) {
      result += a[i] * b[i];
    }
    return result;
  }
  
  private void evictLeastRecentlyUsedBlock() {
    // Simple eviction: remove first block (could be improved with actual LRU tracking)
    if (!loadedBlocks.isEmpty()) {
      Long firstKey = loadedBlocks.keys().nextElement();
      VectorBlock evicted = loadedBlocks.remove(firstKey);
      if (evicted != null) {
        currentMemoryUsage -= evicted.getMemoryFootprint();
      }
    }
  }
  
  /**
   * Clears all loaded blocks and resets memory usage.
   */
  public synchronized void clear() {
    loadedBlocks.clear();
    currentMemoryUsage = 0;
  }
  
  /**
   * Returns current memory usage in bytes.
   */
  public long getCurrentMemoryUsage() {
    return currentMemoryUsage;
  }
  
  /**
   * Returns number of currently loaded blocks.
   */
  public int getLoadedBlockCount() {
    return loadedBlocks.size();
  }
  
  /**
   * Shuts down the executor service. Should be called when done with the buffer.
   */
  public void shutdown() {
    executorService.shutdown();
  }
}