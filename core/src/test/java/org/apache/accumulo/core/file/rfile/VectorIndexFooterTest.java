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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Arrays;
import java.util.List;

import org.junit.jupiter.api.Test;

/**
 * Tests for advanced vector indexing functionality.
 */
public class VectorIndexFooterTest {

  @Test
  public void testHierarchicalIndexBuilding() {
    VectorIndexFooter footer =
        new VectorIndexFooter(3, VectorIndexFooter.IndexingType.HIERARCHICAL);

    // Create some sample centroids
    List<float[]> centroids =
        Arrays.asList(new float[] {1.0f, 0.0f, 0.0f}, new float[] {0.0f, 1.0f, 0.0f},
            new float[] {0.0f, 0.0f, 1.0f}, new float[] {0.5f, 0.5f, 0.0f});

    footer.buildHierarchicalIndex(centroids, 2);

    assertEquals(VectorIndexFooter.IndexingType.HIERARCHICAL, footer.getIndexingType());
    assertEquals(2, footer.getGlobalCentroids().length);
    assertEquals(4, footer.getClusterAssignments().length);
  }

  @Test
  public void testIVFIndexBuilding() {
    VectorIndexFooter footer = new VectorIndexFooter(2, VectorIndexFooter.IndexingType.IVF);

    List<float[]> centroids = Arrays.asList(new float[] {1.0f, 0.0f}, new float[] {0.0f, 1.0f},
        new float[] {-1.0f, 0.0f}, new float[] {0.0f, -1.0f});

    footer.buildIVFIndex(centroids, 2);

    assertEquals(VectorIndexFooter.IndexingType.IVF, footer.getIndexingType());
    assertEquals(2, footer.getGlobalCentroids().length);

    // Each block should be assigned to multiple clusters for better recall
    for (int[] assignment : footer.getClusterAssignments()) {
      assertTrue(assignment.length > 0);
    }
  }

  @Test
  public void testCandidateBlockSelection() {
    VectorIndexFooter footer =
        new VectorIndexFooter(2, VectorIndexFooter.IndexingType.HIERARCHICAL);

    List<float[]> centroids = Arrays.asList(new float[] {1.0f, 0.0f}, new float[] {0.0f, 1.0f},
        new float[] {-1.0f, 0.0f});

    footer.buildHierarchicalIndex(centroids, 2);

    // Query vector close to first centroid
    float[] queryVector = {0.9f, 0.1f};
    List<Integer> candidates = footer.findCandidateBlocks(queryVector, 5);

    assertFalse(candidates.isEmpty());
    assertTrue(candidates.size() <= 5);
  }

  @Test
  public void testFlatIndexing() {
    VectorIndexFooter footer = new VectorIndexFooter(2, VectorIndexFooter.IndexingType.FLAT);

    // For flat indexing, should return all blocks
    float[] queryVector = {0.5f, 0.5f};
    List<Integer> candidates = footer.findCandidateBlocks(queryVector, 10);

    assertEquals(0, candidates.size()); // No blocks configured in this test
  }

  @Test
  public void testIndexTypeEnumeration() {
    assertEquals(0, VectorIndexFooter.IndexingType.FLAT.getTypeId());
    assertEquals(1, VectorIndexFooter.IndexingType.IVF.getTypeId());
    assertEquals(2, VectorIndexFooter.IndexingType.HIERARCHICAL.getTypeId());
    assertEquals(3, VectorIndexFooter.IndexingType.PQ.getTypeId());

    assertEquals(VectorIndexFooter.IndexingType.FLAT,
        VectorIndexFooter.IndexingType.fromTypeId((byte) 0));
    assertEquals(VectorIndexFooter.IndexingType.IVF,
        VectorIndexFooter.IndexingType.fromTypeId((byte) 1));
  }

  @Test
  public void testEmptyIndexBehavior() {
    VectorIndexFooter footer = new VectorIndexFooter();

    float[] queryVector = {1.0f, 0.0f};
    List<Integer> candidates = footer.findCandidateBlocks(queryVector, 5);

    assertTrue(candidates.isEmpty());
  }
}
