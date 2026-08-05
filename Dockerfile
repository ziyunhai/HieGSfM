# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=12.3.1

# -------------------------- 编译构建阶段 Builder --------------------------
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace
# 修复 ccache 绕过问题，确保环境变量正确接管
ENV CC="ccache gcc-11"
ENV CXX="ccache g++-11"

ARG CUDA_ARCHITECTURES="75;80;86"
ARG FETCHCONTENT_FULLY_DISCONNECTED=OFF
ARG INSTALL_PREFIX=/workspace/install
# 锁定指定的 Git Commit 版本
ARG COLMAP_GIT_COMMIT=66fd8e5
ARG POSELIB_GIT_COMMIT=0439b2d

WORKDIR /workspace

# 替换阿里apt源并增加超时防止网络卡死
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 融合官方依赖：补充了 libflann-dev 和 libcgal-dev，并补回 libfreeimage-dev 以替代 OpenImageIO
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git curl wget tar unzip \
    python3-dev python3-pip \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev libflann-dev libcgal-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libtiff-dev libjpeg-dev libpng-dev zlib1g-dev \
    libfreeimage-dev \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# 将 Python 依赖安装到独立的 target 目录，避免与系统环境冲突且方便直接拷贝到 Runtime
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --target=${INSTALL_PREFIX}/python --no-cache-dir scikit-learn scipy numpy progressbar2

# 优化缓存：先 clone 第三方库到 /tmp，并切换到指定的 Commit 版本
# 使用完整 clone 以确保能够准确 checkout 到任意 commit hash，随后更新子模块
RUN git clone https://github.com/PoseLib/PoseLib.git /tmp/PoseLib && \
    cd /tmp/PoseLib && \
    git checkout ${POSELIB_GIT_COMMIT} && \
    git submodule update --init --recursive && \
    git clone https://github.com/colmap/colmap.git /tmp/colmap && \
    cd /tmp/colmap && \
    git checkout ${COLMAP_GIT_COMMIT} && \
    git submodule update --init --recursive

# 拷贝业务代码 (强烈建议在项目根目录添加 .dockerignore 文件，忽略 thirdparty 目录)
COPY . /workspace/project
WORKDIR /workspace/project

# 替换本地可能存在的旧版第三方库，使用刚才 clone 好的纯净版本
RUN rm -rf ./thirdparty/PoseLib ./thirdparty/colmap && \
    mv /tmp/PoseLib ./thirdparty/PoseLib && \
    mv /tmp/colmap ./thirdparty/colmap

# 编译PoseLib
RUN cd ./thirdparty/PoseLib && mkdir build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# 编译COLMAP，关闭GUI (移除了 OpenImageIO_DIR 参数，COLMAP 将自动使用系统 FreeImage)
RUN cd ./thirdparty/colmap && mkdir -p build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCUDA_ENABLED=ON \
    -DGUI_ENABLED=OFF \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DFETCHCONTENT_FULLY_DISCONNECTED=${FETCHCONTENT_FULLY_DISCONNECTED} && \
    ninja install

# 编译业务工程
RUN mkdir -p build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFETCH_COLMAP=OFF \
    -DFETCH_POSELIB=OFF \
    -DTESTS_ENABLED=OFF \
    -DASAN_ENABLED=OFF \
    -DCCACHE_ENABLED=ON \
    -DCUDA_ENABLED=ON \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# ccache缓存导出阶段
FROM scratch AS cache-export
COPY --from=builder /workspace/build/.ccache/ /.ccache/

# -------------------------- 精简运行阶段 Runtime --------------------------
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
# 补充多架构动态库路径，兼容 COLMAP FetchContent 编译的底层库
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:/usr/local/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
# 修复 Warning：直接赋值即可，无需拼接未定义的旧变量
ENV PYTHONPATH=/usr/local/python

WORKDIR /data

# 关键修复：runtime 基础镜像默认不带 universe 源，必须手动追加，否则找不到部分依赖包
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ jammy universe" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ jammy-updates universe" >> /etc/apt/sources.list && \
    echo "deb http://mirrors.aliyun.com/ubuntu/ jammy-security universe" >> /etc/apt/sources.list

# 安装运行依赖库
# 去除了 OpenEXR/Imath，补回了 libfreeimage3 以支持 COLMAP 的图像读写
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends --no-install-suggests \
    python3 python3-pip \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libtiff5 libjpeg8 libpng16-16 zlib1g \
    libfreeimage3 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libflann1.9 libgmp10 libmpfr6 \
    libc6 libgcc-s1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 拷贝编译产出至运行环境系统目录 (包含了 bin, lib, 以及 python 目录)
COPY --from=builder /workspace/install/ /usr/local/

# 更新系统动态链接缓存
RUN ldconfig

# 强制健康检查：如果业务主程序有任何依赖库缺失（not found），直接使构建失败，拦截问题
RUN ldd $(which hie_glomap) | grep "not found" && (echo "ERROR: Missing runtime dependencies!" && exit 1) || true

# 使用 CMD 代替 ENTRYPOINT，允许用户通过 docker run -it <image> /bin/bash 轻松进入容器排查问题
CMD ["hie_glomap"]
