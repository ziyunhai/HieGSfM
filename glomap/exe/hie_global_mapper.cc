#include "glomap/controllers/hierarchical_global_mapper.h"
#include "glomap/controllers/global_mapper.h"
#include "glomap/exe/hie_global_mapper.h"
#include "glomap/math/two_view_geometry.h"
#include "glomap/processors/relpose_filter.h"
#include "glomap/processors/track_filter.h"
#include "glomap/processors/image_undistorter.h"
#include "glomap/estimators/global_positioning.h"
#include "glomap/processors/reconstruction_pruning.h"

#include "glomap/controllers/option_manager.h"
#include "glomap/io/colmap_io.h"
#include "glomap/types.h"
#include "glomap/io/colmap_converter.h"

#include <colmap/util/misc.h>
#include <colmap/util/timer.h>
#include <colmap/sfm/observation_manager.h>
#include <colmap/estimators/alignment.h>
#include <colmap/estimators/bundle_adjustment.h>

namespace glomap {
// -------------------------------------
// Mappers starting from COLMAP database
// -------------------------------------
int RunHieMapper(int argc, char** argv) {
    std::string database_path;
    std::string output_path;

    std::string image_path = "";
    std::string constraint_type = "ONLY_POINTS";
    std::string output_format = "bin";

    OptionManager options;
    options.AddRequiredOption("database_path", &database_path);
    options.AddRequiredOption("output_path", &output_path);
    options.AddDefaultOption("image_path", &image_path);
    options.AddDefaultOption("constraint_type",
                             &constraint_type,
                             "{ONLY_POINTS, ONLY_CAMERAS, "
                             "POINTS_AND_CAMERAS_BALANCED, POINTS_AND_CAMERAS}");
    options.AddDefaultOption("output_format", &output_format, "{bin, txt}");
    options.AddGlobalMapperFullOptions();

    options.Parse(argc, argv);
    if (!colmap::ExistsFile(database_path)) {
      LOG(ERROR) << "`database_path` is not a file";
      return EXIT_FAILURE;
    }

    if (constraint_type == "ONLY_POINTS") {
      options.mapper->opt_gp.constraint_type =
          GlobalPositionerOptions::ONLY_POINTS;
    } else if (constraint_type == "ONLY_CAMERAS") {
      options.mapper->opt_gp.constraint_type =
          GlobalPositionerOptions::ONLY_CAMERAS;
    } else if (constraint_type == "POINTS_AND_CAMERAS_BALANCED") {
      options.mapper->opt_gp.constraint_type =
          GlobalPositionerOptions::POINTS_AND_CAMERAS_BALANCED;
    } else if (constraint_type == "POINTS_AND_CAMERAS") {
      options.mapper->opt_gp.constraint_type =
          GlobalPositionerOptions::POINTS_AND_CAMERAS;
    } else {
      LOG(ERROR) << "Invalid constriant type";
      return EXIT_FAILURE;
    }

    // Check whether output_format is valid
    if (output_format != "bin" && output_format != "txt") {
      LOG(ERROR) << "Invalid output format";
      return EXIT_FAILURE;
    }

    options.database_path = std::make_shared<std::string>(database_path);
    options.output_format = std::make_shared<std::string>(output_format);
    options.image_path = std::make_shared<std::string>(image_path);
    options.output_path = std::make_shared<std::string>(output_path);

    // Load the database
    const colmap::Database database(database_path);
    HierarchicalGlobalMapper hierarchical_global_mapper;

    colmap::Timer run_timer;
    run_timer.Start();
    hierarchical_global_mapper.Run(database, options);
    run_timer.Pause();
    LOG(INFO) << "Reconstruction done in " << run_timer.ElapsedSeconds()
              << " seconds";

  //   // TODO: zy
  //   WriteGlomapReconstruction(
  //       output_path, cameras, images, tracks, output_format, image_path);
  //   LOG(INFO) << "Export to COLMAP reconstruction done";

  return EXIT_SUCCESS;
}
}