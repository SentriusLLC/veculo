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

import java.io.DataInput;
import java.io.DataOutput;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.apache.hadoop.io.Writable;

/**
 * Advanced indexing structure stored in RFile footer for hierarchical vector search. Supports
 * multi-level centroids and cluster assignments for efficient block filtering.
 */
public class VectorIndexFooter implements Writable {

  private int vectorDimension;
  private float[][] globalCentroids; // Top-level cluster centers
  private int[][] clusterAssignments; // Block to cluster mappings
  private byte[] quantizationCodebook; // For product quantization
  private IndexingType indexingType;

  public enum IndexingType {
    FLAT((byte) 0), // Simple centroid-based
    IVF((byte) 1), // Inverted File Index
    HIERARCHICAL((byte) 2), // Multi-level centroids
    PQ((byte) 3); // Product Quantization

    private final byte typeId;

    IndexingType(byte typeId) {
      this.typeId = typeId;
    }

    public byte getTypeId() {
      return typeId;
    }

    public static IndexingType fromTypeId(byte typeId) {
      for (IndexingType type : values()) {
        if (type.typeId == typeId) {
          return type;
        }
      }
      throw new IllegalArgumentException("Unknown IndexingType id: " + typeId);
    }
  }

  public VectorIndexFooter() {
    this.globalCentroids = new float[0][];
    this.clusterAssignments = new int[0][];
    this.quantizationCodebook = new byte[0];
    this.indexingType = IndexingType.FLAT;
  }

  public VectorIndexFooter(int vectorDimension, IndexingType indexingType) {
    this.vectorDimension = vectorDimension;
    this.indexingType = indexingType;
    this.globalCentroids = new float[0][];
    this.clusterAssignments = new int[0][];
    this.quantizationCodebook = new byte[0];
  }

  /**
   * Builds a hierarchical index from vector block centroids using K-means clustering.
   *
   * @param blockCentroids centroids from all vector blocks
   * @param clustersPerLevel number of clusters per hierarchical level
   */
  public void buildHierarchicalIndex(List<float[]> blockCentroids, int clustersPerLevel) {
    if (blockCentroids.isEmpty()) {
      return;
    }

    this.indexingType = IndexingType.HIERARCHICAL;

    // Build top-level clusters using K-means
    this.globalCentroids = performKMeansClustering(blockCentroids, clustersPerLevel);

    // Assign each block to nearest top-level cluster
    this.clusterAssignments = new int[blockCentroids.size()][];
    for (int blockIdx = 0; blockIdx < blockCentroids.size(); blockIdx++) {
      float[] blockCentroid = blockCentroids.get(blockIdx);
      int nearestCluster = findNearestCluster(blockCentroid, globalCentroids);
      this.clusterAssignments[blockIdx] = new int[] {nearestCluster};
    }
  }

  /**
   * Builds an Inverted File Index (IVF) for approximate nearest neighbor search.
   *
   * @param blockCentroids centroids from all vector blocks
   * @param numClusters number of IVF clusters to create
   */
  public void buildIVFIndex(List<float[]> blockCentroids, int numClusters) {
    if (blockCentroids.isEmpty()) {
      return;
    }

    this.indexingType = IndexingType.IVF;

    // Create IVF clusters
    this.globalCentroids = performKMeansClustering(blockCentroids, numClusters);

    // Build inverted file structure - each block maps to multiple clusters
    this.clusterAssignments = new int[blockCentroids.size()][];
    for (int blockIdx = 0; blockIdx < blockCentroids.size(); blockIdx++) {
      float[] blockCentroid = blockCentroids.get(blockIdx);
      // Find top-3 nearest clusters for better recall
      int[] nearestClusters = findTopKNearestClusters(blockCentroid, globalCentroids, 3);
      this.clusterAssignments[blockIdx] = nearestClusters;
    }
  }

  /**
   * Finds candidate blocks for a query vector using the index structure.
   *
   * @param queryVector the query vector
   * @param maxCandidateBlocks maximum number of candidate blocks to return
   * @return list of candidate block indices
   */
  public List<Integer> findCandidateBlocks(float[] queryVector, int maxCandidateBlocks) {
    List<Integer> candidates = new ArrayList<>();

    switch (indexingType) {
      case HIERARCHICAL:
        candidates = findCandidatesHierarchical(queryVector, maxCandidateBlocks);
        break;
      case IVF:
        candidates = findCandidatesIVF(queryVector, maxCandidateBlocks);
        break;
      case FLAT:
      default:
        // For flat indexing, return all blocks (no filtering)
        for (int i = 0; i < clusterAssignments.length; i++) {
          candidates.add(i);
        }
        break;
    }

    return candidates.subList(0, Math.min(candidates.size(), maxCandidateBlocks));
  }

  private List<Integer> findCandidatesHierarchical(float[] queryVector, int maxCandidates) {
    List<Integer> candidates = new ArrayList<>();

    if (globalCentroids.length == 0) {
      return candidates;
    }

    // Find nearest top-level clusters
    int[] nearestClusters =
        findTopKNearestClusters(queryVector, globalCentroids, Math.min(3, globalCentroids.length));

    // Collect all blocks assigned to these clusters
    for (int blockIdx = 0; blockIdx < clusterAssignments.length; blockIdx++) {
      if (clusterAssignments[blockIdx].length > 0) {
        int blockCluster = clusterAssignments[blockIdx][0];
        for (int nearestCluster : nearestClusters) {
          if (blockCluster == nearestCluster) {
            candidates.add(blockIdx);
            break;
          }
        }
      }
    }

    return candidates;
  }

  private List<Integer> findCandidatesIVF(float[] queryVector, int maxCandidates) {
    List<Integer> candidates = new ArrayList<>();

    if (globalCentroids.length == 0) {
      return candidates;
    }

    // Find nearest IVF clusters
    int[] nearestClusters =
        findTopKNearestClusters(queryVector, globalCentroids, Math.min(5, globalCentroids.length));

    // Use inverted file to find candidate blocks
    for (int blockIdx = 0; blockIdx < clusterAssignments.length; blockIdx++) {
      for (int blockCluster : clusterAssignments[blockIdx]) {
        for (int nearestCluster : nearestClusters) {
          if (blockCluster == nearestCluster) {
            candidates.add(blockIdx);
            break;
          }
        }
      }
    }

    return candidates;
  }

  private float[][] performKMeansClustering(List<float[]> points, int k) {
    if (points.isEmpty() || k <= 0) {
      return new float[0][];
    }

    k = Math.min(k, points.size()); // Can't have more clusters than points
    int dimension = points.get(0).length;

    // Initialize centroids randomly
    float[][] centroids = new float[k][dimension];
    for (int i = 0; i < k; i++) {
      // Use point i as initial centroid (simple initialization)
      System.arraycopy(points.get(i * points.size() / k), 0, centroids[i], 0, dimension);
    }

    // K-means iterations (simplified - normally would do multiple iterations)
    int[] assignments = new int[points.size()];

    // Assign points to nearest centroids
    for (int pointIdx = 0; pointIdx < points.size(); pointIdx++) {
      assignments[pointIdx] = findNearestCluster(points.get(pointIdx), centroids);
    }

    // Update centroids
    for (int clusterIdx = 0; clusterIdx < k; clusterIdx++) {
      float[] newCentroid = new float[dimension];
      int count = 0;

      for (int pointIdx = 0; pointIdx < points.size(); pointIdx++) {
        if (assignments[pointIdx] == clusterIdx) {
          float[] point = points.get(pointIdx);
          for (int d = 0; d < dimension; d++) {
            newCentroid[d] += point[d];
          }
          count++;
        }
      }

      if (count > 0) {
        for (int d = 0; d < dimension; d++) {
          newCentroid[d] /= count;
        }
        centroids[clusterIdx] = newCentroid;
      }
    }

    return centroids;
  }

  private int findNearestCluster(float[] point, float[][] centroids) {
    int nearest = 0;
    float minDistance = Float.MAX_VALUE;

    for (int i = 0; i < centroids.length; i++) {
      float distance = euclideanDistance(point, centroids[i]);
      if (distance < minDistance) {
        minDistance = distance;
        nearest = i;
      }
    }

    return nearest;
  }

  private int[] findTopKNearestClusters(float[] point, float[][] centroids, int k) {
    k = Math.min(k, centroids.length);
    float[] distances = new float[centroids.length];

    for (int i = 0; i < centroids.length; i++) {
      distances[i] = euclideanDistance(point, centroids[i]);
    }

    // Find indices of k smallest distances
    Integer[] indices = new Integer[centroids.length];
    for (int i = 0; i < indices.length; i++) {
      indices[i] = i;
    }

    Arrays.sort(indices, (a, b) -> Float.compare(distances[a], distances[b]));

    int[] result = new int[k];
    for (int i = 0; i < k; i++) {
      result[i] = indices[i];
    }

    return result;
  }

  private float euclideanDistance(float[] a, float[] b) {
    float sum = 0.0f;
    for (int i = 0; i < a.length; i++) {
      float diff = a[i] - b[i];
      sum += diff * diff;
    }
    return (float) Math.sqrt(sum);
  }

  // Getters and setters
  public int getVectorDimension() {
    return vectorDimension;
  }

  public float[][] getGlobalCentroids() {
    return globalCentroids;
  }

  public int[][] getClusterAssignments() {
    return clusterAssignments;
  }

  public byte[] getQuantizationCodebook() {
    return quantizationCodebook;
  }

  public IndexingType getIndexingType() {
    return indexingType;
  }

  public void setGlobalCentroids(float[][] globalCentroids) {
    this.globalCentroids = globalCentroids;
  }

  public void setClusterAssignments(int[][] clusterAssignments) {
    this.clusterAssignments = clusterAssignments;
  }

  public void setQuantizationCodebook(byte[] quantizationCodebook) {
    this.quantizationCodebook = quantizationCodebook;
  }

  @Override
  public void write(DataOutput out) throws IOException {
    out.writeInt(vectorDimension);
    out.writeByte(indexingType.getTypeId());

    // Write global centroids
    out.writeInt(globalCentroids.length);
    for (float[] centroid : globalCentroids) {
      out.writeInt(centroid.length);
      for (float value : centroid) {
        out.writeFloat(value);
      }
    }

    // Write cluster assignments
    out.writeInt(clusterAssignments.length);
    for (int[] assignment : clusterAssignments) {
      out.writeInt(assignment.length);
      for (int cluster : assignment) {
        out.writeInt(cluster);
      }
    }

    // Write quantization codebook
    out.writeInt(quantizationCodebook.length);
    if (quantizationCodebook.length > 0) {
      out.write(quantizationCodebook);
    }
  }

  @Override
  public void readFields(DataInput in) throws IOException {
    vectorDimension = in.readInt();
    indexingType = IndexingType.fromTypeId(in.readByte());

    // Read global centroids
    int numCentroids = in.readInt();
    globalCentroids = new float[numCentroids][];
    for (int i = 0; i < numCentroids; i++) {
      int centroidLength = in.readInt();
      globalCentroids[i] = new float[centroidLength];
      for (int j = 0; j < centroidLength; j++) {
        globalCentroids[i][j] = in.readFloat();
      }
    }

    // Read cluster assignments
    int numAssignments = in.readInt();
    clusterAssignments = new int[numAssignments][];
    for (int i = 0; i < numAssignments; i++) {
      int assignmentLength = in.readInt();
      clusterAssignments[i] = new int[assignmentLength];
      for (int j = 0; j < assignmentLength; j++) {
        clusterAssignments[i][j] = in.readInt();
      }
    }

    // Read quantization codebook
    int codebookLength = in.readInt();
    quantizationCodebook = new byte[codebookLength];
    if (codebookLength > 0) {
      in.readFully(quantizationCodebook);
    }
  }
}
