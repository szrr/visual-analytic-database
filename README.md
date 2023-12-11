# visual-analytic-database

VisualDb is a GPU relational database designed for multi visual analytic tasks.

In this project, we provide benchmark of three important tasks in the field of visual analysis, which are similar image search, duplicate video detection and video anomaly detection. You can follow these steps to test the effects of the experiment:

1. Environmental needs

   - a GPU device to execute the GPU relational database queries
   - the c++ version GPU Faiss to execute the ANNS search

   

2. Download big files and put in the corresponding address

   Address: https://mega.nz/folder/L7ZHHLLS#T1Fl-rCHkqvaS5jzNza0DA

   The large files in the above URL need to be placed in separate folders to ensure that the program is executed correctly. 

   For example, ANNS indices in "vector_src/init_vector" folder should all be placed in the same "vector_src/init_vector" address in this project.

   

3. Testing three visual retrieval experiments

   ```bash
   cd benchmark
   ```

   **Similar image search** (SIFT dataset)

   ```bash
   # test recall
   bash sift_acc_.bash
   # test performance
   bash sift_performance_.bash
   ```

   **Duplicate video detection** (SVD dataset)

   ```bash
   # test mAP
   bash video_acc.sh 0 204
   # test performance
   bash video_performance.sh 0 1
   ```

   **Video anomaly detection** (UCSD Ped2 dataset)

   ```bash
   # test AuROC and performance
   bash outlier_acc.sh
   ```
