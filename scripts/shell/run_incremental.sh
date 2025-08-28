# DATASET_PATH=/data2/zhouy/ETH3D/playground/

# /home/zhouy/sfm/hie_sfm/sfm_gd/HieSfM-main/build/src/colmap/exe/colmap feature_extractor \
#    --database_path $DATASET_PATH/database2.db \
#    --image_path $DATASET_PATH/gt/images \
#    --SiftExtraction.use_gpu=1 \
#    --SiftExtraction.gpu_index=0 \

# /home/zhouy/sfm/hie_sfm/sfm_gd/HieSfM-main/build/src/colmap/exe/colmap exhaustive_matcher \
#    --database_path $DATASET_PATH/database2.db \
#    --SiftMatching.num_threads=24 \
#    --SiftMatching.use_gpu=1 \
#    --SiftMatching.gpu_index=0,2 \

# mkdir $DATASET_PATH/colmap

# start_time=$(date +%s)
# /home/zhouy/sfm/hie_sfm/sfm_gd/HieSfM-main/build/src/colmap/exe/colmap mapper \
#     --database_path $DATASET_PATH/database2.db \
#     --image_path $DATASET_PATH/gt/images \
#     --output_path $DATASET_PATH/colmap

# end_time=$(date +%s)
# elapsed_time=$((end_time - start_time))
# echo "The script took $elapsed_time seconds to run."


# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition3-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition6-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge36/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition0-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition4-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge04/ \
#    --max_reproj_error 64

# 模拟对齐策略
# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition7-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition6-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge76/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition3-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition4-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge34/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge34/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge76/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge3476/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition0-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition1-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge01/ \
#    --max_reproj_error 64

# failed
# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition5-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition2-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge52/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge01/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition2-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge012/ \
#    --max_reproj_error 64

# failed -- fix success
# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge012/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/partition5-0/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge0125/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge0125/ \
#    --input_path2 /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge3476/ \
#    --output_path /data2/zhouy/sunyatsan/3_auditorium/hie_glomap_500_100_0.15/merge0123467/ \
#    --max_reproj_error 64

# /usr/local/bin/colmap model_merger \
#    --input_path1 /data2/zhouy/sunyatsan/7_library/hie_glomap_500_100_0.15_mergetest_onlypoints_flatcluster/partition5-0/ \
#    --input_path2 /data2/zhouy/sunyatsan/7_library/hie_glomap_500_100_0.15_mergetest_onlypoints_flatcluster/partition1-0/ \
#    --output_path /data2/zhouy/sunyatsan/7_library/hie_glomap_500_100_0.15_mergetest_onlypoints_flatcluster/merge51_ba/ \
#    --max_reproj_error 64

/home/zhouy/sfm/slam/glomap-main/build/glomap/hie_glomap hie_mapper \
   --input_path1 /data2/zhouy/sunyatsan/7_library/hie_glomap_500_100_0.15_mergetest_onlypoints_flatcluster/partition5-0/ \
   --input_path2 /data2/zhouy/sunyatsan/7_library/hie_glomap_500_100_0.15_mergetest_onlypoints_flatcluster/partition1-0/ \
   --output_path /data2/zhouy/sunyatsan/7_library/hie_glomap_500_100_0.15_mergetest_onlypoints_flatcluster/merge51_ba/ \
   --max_reproj_error 64 \
   --database_path /data2/zhouy/sunyatsan/7_library/database_knn5_200.db

