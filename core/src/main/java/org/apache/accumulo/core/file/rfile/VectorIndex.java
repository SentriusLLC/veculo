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
import java.util.List;

import org.apache.hadoop.io.Writable;

/**
 * Vector index metadata for RFile blocks containing vector data.
 * This enables efficient vector similarity searches by storing centroids
 * and other metadata for coarse filtering.
 */
public class VectorIndex implements Writable {
  
  /**
   * Metadata for a single vector block.
   */
  public static class VectorBlockMetadata implements Writable {
    private float[] centroid;
    private int vectorCount;
    private long blockOffset;
    private int blockSize;
    
    public VectorBlockMetadata() {
      // Default constructor for Writable
    }
    
    public VectorBlockMetadata(float[] centroid, int vectorCount, long blockOffset, int blockSize) {
      this.centroid = centroid;
      this.vectorCount = vectorCount;
      this.blockOffset = blockOffset;
      this.blockSize = blockSize;
    }
    
    public float[] getCentroid() {
      return centroid;
    }
    
    public int getVectorCount() {
      return vectorCount;
    }
    
    public long getBlockOffset() {
      return blockOffset;
    }
    
    public int getBlockSize() {
      return blockSize;
    }
    
    @Override
    public void write(DataOutput out) throws IOException {
      out.writeInt(centroid.length);
      for (float value : centroid) {
        out.writeFloat(value);
      }
      out.writeInt(vectorCount);
      out.writeLong(blockOffset);
      out.writeInt(blockSize);
    }
    
    @Override
    public void readFields(DataInput in) throws IOException {
      int dimension = in.readInt();
      centroid = new float[dimension];
      for (int i = 0; i < dimension; i++) {
        centroid[i] = in.readFloat();
      }
      vectorCount = in.readInt();
      blockOffset = in.readLong();
      blockSize = in.readInt();
    }
  }
  
  private int vectorDimension;
  private List<VectorBlockMetadata> blocks;
  
  public VectorIndex() {
    this.blocks = new ArrayList<>();
  }
  
  public VectorIndex(int vectorDimension) {
    this.vectorDimension = vectorDimension;
    this.blocks = new ArrayList<>();
  }
  
  public void addBlock(VectorBlockMetadata block) {
    blocks.add(block);
  }
  
  public List<VectorBlockMetadata> getBlocks() {
    return blocks;
  }
  
  public int getVectorDimension() {
    return vectorDimension;
  }
  
  public void setVectorDimension(int vectorDimension) {
    this.vectorDimension = vectorDimension;
  }
  
  @Override
  public void write(DataOutput out) throws IOException {
    out.writeInt(vectorDimension);
    out.writeInt(blocks.size());
    for (VectorBlockMetadata block : blocks) {
      block.write(out);
    }
  }
  
  @Override
  public void readFields(DataInput in) throws IOException {
    vectorDimension = in.readInt();
    int blockCount = in.readInt();
    blocks = new ArrayList<>(blockCount);
    for (int i = 0; i < blockCount; i++) {
      VectorBlockMetadata block = new VectorBlockMetadata();
      block.readFields(in);
      blocks.add(block);
    }
  }
}