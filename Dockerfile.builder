# syntax=docker/dockerfile:1
# HieGSfM Builder Dockerfile — vcpkg 版本
# 依赖管理由 vcpkg (vcpkg.json) 统一接管，apt-get 仅安装基础编译工具链。
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

# 仅安装基础编译工具链 + vcpkg 引导依赖
# 其余 C++ 库（boost, ceres, eigen3, flann, freeimage, glog, suitesparse 等）全部由 vcpkg 管理
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends \
    build-essential gcc-11 g++-11 \
    cmake ninja-build \
    git curl wget tar unzip zip \
    pkg-config \
    python3 python3-pip \
    autoconf autoconf-archive automake libtool \
    gfortran \
    libgl-dev libglx-dev libegl-dev libglew-dev \
    && rm -rf /var/lib/apt/lists/*

# 升级 CMake 到 3.28.6（项目要求 >= 3.27）
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz && \
    tar -zxf cmake-3.28.6-linux-x86_64.tar.gz -C /opt/ && \
    rm cmake-3.28.6-linux-x86_64.tar.gz && \
    ln -s /opt/cmake-3.28.6-linux-x86_64/bin/* /usr/local/bin/

# 引导 vcpkg
RUN git clone --depth 1 https://github.com/Microsoft/vcpkg.git /opt/vcpkg && \
    /opt/vcpkg/bootstrap-vcpkg.sh

ENV VCPKG_ROOT=/opt/vcpkg
ENV CMAKE_TOOLCHAIN_FILE=${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake

# ======================== 拷贝项目源码 ========================
# thirdparty/PoseLib 和 thirdparty/colmap 已由 CI 在宿主机上 git clone 完成
COPY . /workspace/project
WORKDIR /workspace/project

# vcpkg 清单模式安装所有依赖（自动读取 vcpkg.json）
RUN /opt/vcpkg/vcpkg install --clean-after-build --triplet x64-linux

# 记录 vcpkg 安装路径，供后续编译阶段引用
ENV VCPKG_INSTALLED_DIR=/workspace/project/vcpkg_installed/x64-linux

# Python 依赖
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --target=${INSTALL_PREFIX}/python --no-cache-dir \
    scikit-learn scipy numpy progressbar2

# ======================== 编译 PoseLib ========================
# 不使用 vcpkg toolchain，通过 CMAKE_PREFIX_PATH 找到 vcpkg 安装的 Eigen3
RUN mkdir -p thirdparty/PoseLib/build && cd thirdparty/PoseLib/build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
    -DCMAKE_PREFIX_PATH="${VCPKG_INSTALLED_DIR}" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# ======================== 编译 COLMAP ========================
# 关闭 GUI，开启 CUDA 加速
# 不使用 vcpkg toolchain，通过 CMAKE_PREFIX_PATH 找到 vcpkg 安装的依赖
RUN mkdir -p thirdparty/colmap/build && cd thirdparty/colmap/build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
    -DCMAKE_PREFIX_PATH="${VCPKG_INSTALLED_DIR}" \
    -DCUDA_ENABLED=ON \
    -DGUI_ENABLED=OFF \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON && \
    ninja install

# ======================== 编译 HieGSfM 主工程 ========================
# FETCH_COLMAP=OFF / FETCH_POSELIB=OFF：使用已编译安装的第三方库
RUN mkdir build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE} \
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
    libgl1 libglx0 libegl1 libglew2.2 \
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