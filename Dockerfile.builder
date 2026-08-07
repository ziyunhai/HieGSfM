# syntax=docker/dockerfile:1
# HieGSfM Builder Dockerfile
# 依赖分层管理：
#   - PoseLib / COLMAP → apt-get 系统包（第三方项目自带 vcpkg，避免冲突）
#   - HieGSfM 主工程   → vcpkg 清单模式（vcpkg.json）
# thirdparty 代码（PoseLib、COLMAP）由 CI 工作流在宿主机上预先下载，
# 通过 COPY 指令带入构建上下文，避免 Docker 内重复 git clone。

# ======================== 全局构建参数 ========================
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=12.3.1
ARG CUDA_ARCHITECTURES="75;80;86"
ARG INSTALL_PREFIX=/workspace/install
ARG BUILD_TYPE=Release

# ======================== 编译构建阶段 ========================
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-11
ENV CXX=g++-11

WORKDIR /workspace

# 替换阿里云 apt 镜像源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 基础编译工具链 + PoseLib / COLMAP 系统依赖
# PoseLib 仅需 Eigen3；COLMAP 需要 boost/ceres/flann/freeimage/glew/glog/suitesparse 等
# 使用 apt-get 安装，避免 COLMAP 内建 vcpkg 触发独立的子进程 vcpkg install
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends \
    build-essential gcc-11 g++-11 \
    cmake ninja-build \
    git curl wget tar unzip \
    pkg-config \
    python3 python3-pip \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev libflann-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev \
    libfreeimage-dev \
    libgl-dev libglx-dev libegl-dev libglew-dev \
    libsqlite3-dev liblz4-dev \
    libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# 升级 CMake 到 3.28.6（项目要求 >= 3.27）
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz && \
    tar -zxf cmake-3.28.6-linux-x86_64.tar.gz -C /opt/ && \
    rm cmake-3.28.6-linux-x86_64.tar.gz && \
    ln -s /opt/cmake-3.28.6-linux-x86_64/bin/* /usr/local/bin/

# 引导 vcpkg（仅主工程 HieGSfM 使用，PoseLib/COLMAP 走 apt-get）
RUN git clone --depth 1 https://github.com/Microsoft/vcpkg.git /opt/vcpkg && \
    /opt/vcpkg/bootstrap-vcpkg.sh

ENV VCPKG_ROOT=/opt/vcpkg

# ======================== 拷贝项目源码 ========================
# thirdparty/PoseLib 和 thirdparty/colmap 已由 CI 在宿主机上 git clone 完成
COPY . /workspace/project
WORKDIR /workspace/project

# Python 依赖
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --target=${INSTALL_PREFIX}/python --no-cache-dir \
    scikit-learn scipy numpy progressbar2

# ======================== 编译 PoseLib ========================
# apt-get 已安装 Eigen3，无需 vcpkg toolchain
RUN mkdir -p thirdparty/PoseLib/build && cd thirdparty/PoseLib/build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# ======================== 编译 COLMAP ========================
# 关闭 GUI，开启 CUDA 加速。依赖全部由 apt-get 提供，不使用 vcpkg toolchain
# 避免 COLMAP 内建 vcpkg.json 触发独立的子进程 vcpkg install
RUN mkdir -p thirdparty/colmap/build && cd thirdparty/colmap/build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
    -DCUDA_ENABLED=ON \
    -DGUI_ENABLED=OFF \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON && \
    ninja install

# ======================== 编译 HieGSfM 主工程 ========================
# 使用 vcpkg toolchain 管理 vcpkg.json 中声明的依赖
# FETCH_COLMAP=OFF / FETCH_POSELIB=OFF：使用已编译安装的第三方库
RUN mkdir build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
    -DCMAKE_TOOLCHAIN_FILE=${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_PREFIX_PATH="${INSTALL_PREFIX}" \
    -DFETCH_COLMAP=OFF \
    -DFETCH_POSELIB=OFF \
    -DTESTS_ENABLED=OFF \
    -DASAN_ENABLED=OFF \
    -DCUDA_ENABLED=ON \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# ======================== 构建产物校验 ========================
RUN echo "=== 构建产物 ===" && ls -la ${INSTALL_PREFIX}/bin/ && \
    ldd ${INSTALL_PREFIX}/bin/hie_glomap | grep "not found" && \
    (echo "ERROR: Missing dynamic libraries!"; exit 1) || true && \
    echo "=== 构建完成 ==="

# ======================== 精简运行阶段 ========================
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=12.3.1
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:/usr/local/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
ENV PYTHONPATH=/usr/local/python/lib/python3.10/site-packages
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics

WORKDIR /data

# 阿里云源 + 最小运行依赖（vcpkg 静态链接，无需安装 -dev 包）
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g; s/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
EOF

RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends --no-install-suggests \
	    python3 python3-pip \
	    libnvidia-gl-545 \
	    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
	    libceres2 libgoogle-glog0v5 libgflags2.2 \
	    libfreeimage3 \
	    libgl1 libglx0 libegl1 libglew2.2 \
	    libsqlite3-0 liblz4-1 \
	    libmetis5 libflann1.9 libsuitesparseconfig5.1.0 \
	    libgomp1 \
	    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 从 builder 阶段复制编译产物
COPY --from=builder /workspace/install/ /usr/local/
RUN ldconfig

# 前置校验
RUN if ! command -v hie_glomap; then echo "ERROR: hie_glomap not found!"; exit 1; fi && \
    ldd $(which hie_glomap) | grep "not found" && (echo "ERROR: Missing runtime libraries!"; exit 1) || true

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pgrep hie_glomap || exit 1

CMD ["hie_glomap"]