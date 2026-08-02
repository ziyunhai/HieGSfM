# ====================== 第一阶段：编译构建阶段 builder ======================
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-9
ENV CXX=g++-9

WORKDIR /workspace

# 1. 系统全套编译依赖，使用apt直接安装libceres-dev
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-dev \
    python3-numpy \
    python3-scipy \
    git \
    cmake \
    vim \
    wget \
    build-essential \
    pkg-config \
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-regex-dev \
    libboost-system-dev \
    libboost-test-dev \
    libboost-serialization-dev \
    libboost-heap-dev \
    libboost-property-tree-dev \
    libeigen3-dev \
    libsuitesparse-dev \
    libatlas-base-dev \
    libblas-dev \
    liblapack-dev \
    libmetis-dev \
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
    autoconf automake libtool flex bison gcc-9 g++-9 \
    libgtest-dev \
    ninja-build \
    ccache \
    libceres-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. Python三方依赖安装
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir \
        scikit-learn \
        scipy \
        numpy \
        progressbar2

# 3. 编译安装 PoseLib
RUN git clone --recursive https://github.com/PoseLib/PoseLib.git /tmp/PoseLib && \
    cd /tmp/PoseLib && \
    mkdir build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/PoseLib

# 4. 复制项目源码
COPY . /workspace/project

# 5. 构建主项目GLOMAP/HIE_GLOMAP
RUN cd /workspace/project && \
    mkdir build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DFETCH_COLMAP=ON \
        -DFETCH_POSELIB=OFF \
        -DTESTS_ENABLED=OFF \
        -DASAN_ENABLED=OFF \
        -DCCACHE_ENABLED=ON \
        -DCUDA_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="35;50;52;60;61;70;75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" && \
    ninja && \
    ninja install

RUN ldconfig

# ====================== 第二阶段：运行时镜像 runtime ======================
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-regex-dev \
    libboost-system-dev \
    libboost-serialization-dev \
    libeigen3-dev \
    libsuitesparse-dev \
    libatlas-base-dev \
    libblas-dev \
    liblapack-dev \
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
    libsqlite3-0 \
    libceres-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/include /usr/local/include
COPY --from=builder /usr/local/share /usr/local/share

COPY --from=builder /usr/local/lib/python3.8/dist-packages /usr/local/lib/python3.8/dist-packages
COPY --from=builder /usr/bin/python3 /usr/bin/python3
COPY --from=builder /usr/bin/pip3 /usr/bin/pip3

RUN ldconfig

ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH

WORKDIR /data

ENTRYPOINT ["glomap"]
