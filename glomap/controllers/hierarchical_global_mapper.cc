#include "hierarchical_global_mapper.h"
#include "global_mapper.h"
#include "glomap/io/colmap_io.h"
#include "glomap/processors/image_undistorter.h"

#include "colmap/estimators/alignment.h"
#include "colmap/scene/scene_clustering.h"
#include "colmap/scene/reconstruction_manager.h"
#include "colmap/util/misc.h"
#include "colmap/util/threading.h"
#include "colmap/controllers/hierarchical_mapper.h"

namespace glomap {

void MergeClusters(const colmap::SceneClustering::Cluster& cluster,
                   std::unordered_map<const colmap::SceneClustering::Cluster*,
                                      std::shared_ptr<colmap::ReconstructionManager>>*
                       reconstruction_managers) {
  // Extract all reconstructions from all child clusters.
  std::vector<std::shared_ptr<colmap::Reconstruction>> reconstructions;
  for (const auto& child_cluster : cluster.child_clusters) {
    if (!child_cluster.child_clusters.empty()) {
      MergeClusters(child_cluster, reconstruction_managers);
    }

    auto& reconstruction_manager = reconstruction_managers->at(&child_cluster);
    for (size_t i = 0; i < reconstruction_manager->Size(); ++i) {
      reconstructions.push_back(reconstruction_manager->Get(i));
    }
  }

  // Try to merge all child cluster reconstruction.
  while (reconstructions.size() > 1) {
    bool merge_success = false;
    std::sort(reconstructions.begin(),
            reconstructions.end(),
            [](const std::shared_ptr<colmap::Reconstruction>& reconstruction1,
               const std::shared_ptr<colmap::Reconstruction>& reconstruction2) {
              return reconstruction1->NumRegImages() < reconstruction2->NumRegImages();
            });

    for (size_t i = 0; i < reconstructions.size(); ++i) {
      const int num_reg_images_i = reconstructions[i]->NumRegImages();
      for (size_t j = 0; j < i; ++j) {
        const double kMaxReprojError = 64.0; // 8.0 
        const int num_reg_images_j = reconstructions[j]->NumRegImages();

        std::unordered_set<image_t> common_image_ids;
        if (colmap::MergeReconstructionsWithCommonImages(kMaxReprojError,
                                                         *reconstructions[j],
                                                         *reconstructions[i],
                                                         common_image_ids)) {
          // 构造images, 构造cameras
          std::unordered_map<camera_t, Camera> cameras;
          std::unordered_map<image_t, Image> images;
          std::unordered_map<track_t, Track> tracks;
          ViewGraph view_graph;
          bool use_ba = true;
          if (use_ba) {
            ConvertColmapToGlomap(*reconstructions[i], cameras, images, tracks);
            BundleAdjusterOptions options_ba;
            BundleAdjuster ba_engine(options_ba);
            BundleAdjusterOptions& ba_engine_options_inner =
                ba_engine.GetOptions();
            ba_engine_options_inner.optimize_rotations = false;
            ba_engine.Solve(view_graph, cameras, images, tracks);

            // PruneWeaklyConnectedImages(images, tracks);
            ConvertGlomapToColmap(cameras, images, tracks, *reconstructions[i]);
          }

          // 构造view_graph     
          bool use_ra_pa = false;
          if (use_ra_pa) {
            for (auto& [track_id, track] : tracks) {
              if (track.observations.size() < 2) continue;
              for (size_t i = 0; i < track.observations.size(); i++) {
                for (size_t j = i + 1; j < track.observations.size(); j++) {
                  image_t image_id1 = track.observations[i].first;
                  image_t image_id2 = track.observations[j].first;
                  if (image_id1 == image_id2) continue;
                  image_pair_t pair_id =
                      ImagePair::ImagePairToPairId(image_id1, image_id2);
                  view_graph.image_pairs.insert(
                      std::make_pair(pair_id, ImagePair(image_id1, image_id2)));
                }
              }
            }

            RotationEstimatorOptions options_ra;
            RotationEstimator ra_engine(options_ra);
            // The first run is for filtering
            ra_engine.EstimateRotations(view_graph, images);

            GlobalPositionerOptions options_pa;
            options_pa.generate_random_positions = false;
            options_pa.generate_random_points = false;

            UndistortImages(cameras, images, false);
            GlobalPositioner gp_engine(options_pa);
            gp_engine.Solve(view_graph, cameras, images, tracks);
          }

          LOG(INFO) << colmap::StringPrintf(
              "=> Merged clusters with %d and %d images into %d images",
              num_reg_images_i,
              num_reg_images_j,
              reconstructions[i]->NumRegImages());
          reconstructions.erase(reconstructions.begin() + j);
          merge_success = true;

          // // Configure bundle adjustment for overlappint regions
          // if (common_image_ids.empty()) {
          //   break;
          // }
          // image_t first_id = *common_image_ids.begin();

          // colmap::BundleAdjustmentOptions ba_options;
          // colmap::BundleAdjustmentConfig ba_config;
          // for (const image_t image_id : common_image_ids) {
          //   ba_config.AddImage(image_id);
          // }
          // auto it = common_image_ids.begin();
          // ba_config.SetConstantCamPose(*it);
          // it++;
          // ba_config.SetConstantCamPositions(*it, {0});

          // // Run bundle adjustment.
          // colmap::BundleAdjuster bundle_adjuster(ba_options, ba_config);
          // bundle_adjuster.Solve(reconstructions[i].get());
          break;
        } else {
          LOG(INFO) << colmap::StringPrintf(
              "=> Failed Merged clusters with %d and %d images into %d images",
              num_reg_images_i,
              num_reg_images_j,
              reconstructions[i]->NumRegImages());
        }
      }

      if (merge_success) {
        break;
      }
    }

    if (!merge_success) {
      break;
    }
  }

  // Insert a new reconstruction manager for merged cluster.
  auto& reconstruction_manager = (*reconstruction_managers)[&cluster];
  reconstruction_manager = std::make_shared<colmap::ReconstructionManager>();
  for (const auto& reconstruction : reconstructions) {
    reconstruction_manager->Get(reconstruction_manager->Add()) = reconstruction;
  }

  // Delete all merged child cluster reconstruction managers.
  for (const auto& child_cluster : cluster.child_clusters) {
    reconstruction_managers->erase(&child_cluster);
  }
}

bool HierarchicalGlobalMapper::Run(const colmap::Database& database,
                         OptionManager& options) {  
    //////////////////////////////////////////////////////////////////////////////
    // Cluster scene graph
    //////////////////////////////////////////////////////////////////////////////
    colmap::PrintHeading1("Partitioning scene");
    options.clustering_options.completeness_ratio = 0.15;
    options.clustering_options.leaf_max_num_images = 500;
    options.clustering_options.image_overlap = 50;
    options.clustering_options.is_hierarchical = false;
    options.clustering_options.branching = 8;
    colmap::SceneClustering scene_clustering =
        colmap::SceneClustering::Create(options.clustering_options, database);

    auto leaf_clusters = scene_clustering.GetLeafClusters();

    size_t total_num_images = 0;
    for (size_t i = 0; i < leaf_clusters.size(); ++i) {
        total_num_images += leaf_clusters[i]->image_ids.size();
        LOG(INFO) << colmap::StringPrintf("  Cluster %d with %d images",
                                i + 1,
                                leaf_clusters[i]->image_ids.size());
    }
    LOG(INFO) << colmap::StringPrintf("Clusters have %d images", total_num_images);

    // Start reconstructing the bigger clusters first for better resource usage.
    std::sort(leaf_clusters.begin(),
            leaf_clusters.end(),
            [](const colmap::SceneClustering::Cluster* cluster1,
               const colmap::SceneClustering::Cluster* cluster2) {
              return cluster1->image_ids.size() > cluster2->image_ids.size();
            });

    //////////////////////////////////////////////////////////////////////////////
    // Reconstruct clusters
    //////////////////////////////////////////////////////////////////////////////
    colmap::PrintHeading1("Reconstructing clusters");
    // Determine the number of workers and threads per worker.
    const int kMaxNumThreads = -1;
    const int num_eff_threads = colmap::GetEffectiveNumThreads(kMaxNumThreads);
    const int kDefaultNumWorkers = 8;
    const int num_eff_workers = std::min(static_cast<int>(leaf_clusters.size()),std::min(kDefaultNumWorkers, num_eff_threads));
    const int num_threads_per_worker =
        std::max(1, num_eff_threads / num_eff_workers);
    
    // 生成分块global sfm的任务
    std::unordered_map<const colmap::SceneClustering::Cluster*, std::shared_ptr<colmap::ReconstructionManager>> reconstruction_managers;
    reconstruction_managers.reserve(leaf_clusters.size());

    // Function to reconstruct one cluster using incremental mapping.
    colmap::Timer run_timer;
    run_timer.Start();
    auto ReconstructCluster =
      [&, this](const colmap::SceneClustering::Cluster& cluster,
                std::shared_ptr<colmap::ReconstructionManager> reconstruction_manager) {
        if (cluster.image_ids.empty()) {
            LOG(INFO) << "No images found in the cluster";
            return;
        }

        GlobalMapperOptions glomap_mapper_options;
        glomap_mapper_options.image_set_ids_.clear();
        for (const auto image_id : cluster.image_ids) {
            glomap_mapper_options.image_set_ids_.insert(image_id);
        }

        glomap_mapper_options.skip_bundle_adjustment = false;
        glomap_mapper_options.skip_retriangulation = true;
        glomap_mapper_options.skip_pruning = true;
 
        GlobalMapper global_mapper(glomap_mapper_options, *options.database_path, *options.image_path, std::move(reconstruction_manager));
        
        global_mapper.Start();
        global_mapper.Wait();
      };

    colmap::ThreadPool thread_pool(num_eff_workers);
    for (const auto& cluster : leaf_clusters) {
        reconstruction_managers[cluster] = std::make_shared<colmap::ReconstructionManager>();
        thread_pool.AddTask(ReconstructCluster, *cluster, reconstruction_managers[cluster]);
    }
    thread_pool.Wait();

    run_timer.Pause();
    LOG(INFO) << "Reconstruction done in " << run_timer.ElapsedSeconds()
              << " seconds";

    bool write_sub_models = true;
    if (write_sub_models) {
      for (size_t k = 0; k < leaf_clusters.size(); k++) {
        auto& recon_manager = reconstruction_managers[leaf_clusters[k]];
        for (size_t i = 0; i < recon_manager->Size(); i++) {
          const std::string reconstruction_path = colmap::JoinPaths(*options.output_path, "partition" + std::to_string(k) + "-" +  std::to_string(i));
          colmap::CreateDirIfNotExists(reconstruction_path);
          recon_manager->Get(i)->Write(reconstruction_path);
        }
      }
    }

    bool read_sub_models = false;
    if (read_sub_models) {
      for (size_t k = 0; k < leaf_clusters.size(); k++) {
        const std::string reconstruction_path = colmap::JoinPaths(*options.output_path, "partition" + std::to_string(k) + "-" +  std::to_string(0));
        auto& recon_manager = reconstruction_managers[leaf_clusters[k]];
        recon_manager = std::make_shared<colmap::ReconstructionManager>();
        auto model_id = recon_manager->Add();
        recon_manager->Get(0)->Read(reconstruction_path);
      }
    }
    
    //////////////////////////////////////////////////////////////////////////////
    // Merge clusters
    //////////////////////////////////////////////////////////////////////////////
    colmap::PrintHeading1("Merging clusters");

    MergeClusters(*scene_clustering.GetRootCluster(), &reconstruction_managers);

    CHECK_EQ(reconstruction_managers.size(), 1);
    CHECK_GT(reconstruction_managers.begin()->second->Get(0)->NumRegImages(), 0);

    std::shared_ptr<colmap::ReconstructionManager> merged_manager = reconstruction_managers.begin()->second;
    merged_manager->Write(*options.output_path);
    return true;
}
}