# ============================================================
# HIE_GLOMAP 多阶段构建 Dockerfile
# ============================================================

# ====================== 第一阶段：编译构建 ======================
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-9
ENV CXX=g++-9

WORKDIR /workspace

# 升级CMake到3.27+
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    ca-certificates \
    && wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null \
    && echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ focal main' | tee /etc/apt/sources.list.d/kitware.list >/dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

# 安装系统编译依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ninja-build \
    git \
    pkg-config \
    ccache \
    vim \
    python3-dev \
    python3-pip \
    python3-numpy \
    python3-scipy \
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-regex-dev \
    libboost-system-dev \
    libboost-test-dev \
    libboost-serialization-dev \
    libboost-heap-dev \
    libboost-property-tree-dev \
    libboost-property-map-dev \
    libeigen3-dev \
    libsuitesparse-dev \
    libatlas-base-dev \
    libblas-dev \
    liblapack-dev \
    libmetis-dev \
    libceres-dev \
    libfreeimage-dev \
    libflann-dev \
    libjasper-dev \
    libgoogle-glog-dev \
    libgflags-dev \
    libglew-dev \
    qtbase5-dev \
    libqt5opengl5-dev \
    libcgal-dev \
    libcgal-qt5-dev \
    libxml2-dev \
    libomp-dev \
    libsqlite3-dev \
    libgtest-dev \
    autoconf \
    automake \
    libtool \
    flex \
    bison \
    gcc-9 \
    g++-9 \
    && rm -rf /var/lib/apt/lists/*

# 安装Python三方依赖
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir \
        scikit-learn \
        scipy \
        numpy \
        progressbar2

# 复制项目源码
COPY . /workspace/project

# 清空thirdparty目录，防止CI子模块残留冲突
RUN rm -rf /workspace/project/thirdparty/PoseLib && \
    rm -rf /workspace/project/thirdparty/colmap

# 拉取PoseLib源码到thirdparty
RUN git clone --recursive https://github.com/PoseLib/PoseLib.git /workspace/project/thirdparty/PoseLib

# 拉取COLMAP源码到thirdparty
RUN git clone --recursive https://github.com/colmap/colmap.git /workspace/project/thirdparty/colmap

# 构建PoseLib
RUN cd /workspace/project/thirdparty/PoseLib && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    make -j$(nproc) && \
    make install

# 构建COLMAP
RUN cd /workspace/project/thirdparty/colmap && \
    mkdir -p build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON \
        -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="35;50;52;60;61;70;75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" && \
    ninja -j$(nproc) && \
    ninja install

# 构建主项目hie_glomap
RUN cd /workspace/project && \
    mkdir -p build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DFETCH_COLMAP=OFF \
        -DFETCH_POSELIB=OFF \
        -DTESTS_ENABLED=OFF \
        -DASAN_ENABLED=OFF \
        -DCCACHE_ENABLED=ON \
        -DCUDA_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="35;50;52;60;61;70;75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" && \
    ninja -j$(nproc) && \
    ninja install

RUN ldconfig

# ====================== 第二阶段：运行时镜像 ======================
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH

WORKDIR /data

# 安装运行时依赖
# 说明：libjasper、libcgal、libflann运行时包名在Ubuntu 20.04中不统一，
# 暂用-dev包保证依赖完整可用，后续可通过ldd排查精确裁剪
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    libboost-program-options1.71.0 \
    libboost-filesystem1.71.0 \
    libboost-graph1.71.0 \
    libboost-regex1.71.0 \
    libboost-system1.71.0 \
    libboost-serialization1.71.0 \
    libgomp1 \
    libblas3 \
    liblapack3 \
    libatlas3-base \
    libceres1 \
    libfreeimage3 \
    libflann-dev \
    libjasper-dev \
    libgoogle-glog0v5 \
    libgflags2.2 \
    libglew2.1 \
    libqt5opengl5 \
    libqt5widgets5 \
    libcgal-dev \
    libxml2 \
    libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# 复制编译产物
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/include /usr/local/include
COPY --from=builder /usr/local/share /usr/local/share

# 复制Python环境
COPY --from=builder /usr/local/lib/python3.8/dist-packages /usr/local/lib/python3.8/dist-packages
COPY --from=builder /usr/bin/python3 /usr/bin/python3
COPY --from=builder /usr/bin/pip3 /usr/bin/pip3

RUN ldconfig

ENTRYPOINT ["hie_glomap"]
