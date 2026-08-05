# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=22.04
ARG NVIDIA_CUDA_VERSION=12.3.1
ARG CUDA_ARCHITECTURES="75;80;86"
ARG FETCHCONTENT_FULLY_DISCONNECTED=OFF
ARG INSTALL_PREFIX=/workspace/install
ARG COLMAP_GIT_COMMIT=66fd8e5
ARG POSELIB_GIT_COMMIT=0439b2d

# -------------------------- Builder 编译阶段 --------------------------
FROM nvidia/cuda:${NVIDIA_CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CC=gcc-11
ENV CXX=g++-11

WORKDIR /workspace

# 替换阿里apt源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 1. 安装基础编译依赖（剔除ccache）
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends \
    ninja-build build-essential gcc-11 g++-11 git curl wget tar unzip \
    python3-dev python3-pip \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev libflann-dev libcgal-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libtiff-dev libjpeg-dev libpng-dev zlib1g-dev \
    libfreeimage-dev \
    libgl-dev libglx-dev libegl-dev libglew-dev \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. 安装 CMake 3.28.6 满足 >=3.27 要求
RUN wget https://github.com/Kitware/CMake/releases/download/v3.28.6/cmake-3.28.6-linux-x86_64.tar.gz && \
    tar -zxvf cmake-3.28.6-linux-x86_64.tar.gz -C /opt/ && \
    rm -f cmake-3.28.6-linux-x86_64.tar.gz && \
    ln -s /opt/cmake-3.28.6-linux-x86_64/bin/* /usr/local/bin/ && \
    cmake --version

# Python依赖安装至独立目录
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --target=${INSTALL_PREFIX}/python --no-cache-dir scikit-learn scipy numpy progressbar2

# 拉取固定commit第三方库
RUN git clone https://github.com/PoseLib/PoseLib.git /tmp/PoseLib && \
    cd /tmp/PoseLib && git checkout ${POSELIB_GIT_COMMIT} && git submodule update --init --recursive && \
    git clone https://github.com/colmap/colmap.git /tmp/colmap && \
    cd /tmp/colmap && git checkout ${COLMAP_GIT_COMMIT} && git submodule update --init --recursive

# 拷贝项目代码
COPY . /workspace/project
WORKDIR /workspace/project

# 替换第三方库，清理临时文件
RUN rm -rf ./thirdparty/PoseLib ./thirdparty/colmap && \
    mv /tmp/PoseLib ./thirdparty/PoseLib && \
    mv /tmp/colmap ./thirdparty/colmap && \
    rm -rf /tmp/*

# 编译 PoseLib
RUN mkdir -p thirdparty/PoseLib/build && cd thirdparty/PoseLib/build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# 编译 COLMAP
RUN mkdir -p thirdparty/colmap/build && cd thirdparty/colmap/build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCUDA_ENABLED=ON \
    -DGUI_ENABLED=OFF \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DFETCHCONTENT_FULLY_DISCONNECTED=${FETCHCONTENT_FULLY_DISCONNECTED} && \
    ninja install

# 编译业务工程：已彻底删除全部ccache相关参数
RUN mkdir build && cd build && \
    cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFETCH_COLMAP=OFF \
    -DFETCH_POSELIB=OFF \
    -DTESTS_ENABLED=OFF \
    -DASAN_ENABLED=OFF \
    -DCUDA_ENABLED=ON \
    -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES} \
    -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} && \
    ninja install

# -------------------------- Runtime 运行阶段 --------------------------
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

# 重置完整阿里源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g; s/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
EOF

# 运行时依赖
RUN apt-get update -o Acquire::http::Timeout=60 && apt-get install -y --no-install-recommends --no-install-suggests \
    python3 python3-pip libnvidia-gl-545 \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libtiff5 libjpeg8 libpng16-16 zlib1g \
    libfreeimage3 \
    libgl1 libglx0 libegl1 libglew2.2 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libflann1.9 libgmp10 libmpfr6 \
    libc6 libgcc-s1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 拷贝编译产物
COPY --from=builder /workspace/install/ /usr/local/

RUN ldconfig

# 二进制与依赖校验
RUN if ! command -v hie_glomap; then echo "ERROR: hie_glomap binary missing!"; exit 1; fi && \
    ldd $(which hie_glomap) | grep "not found" && (echo "ERROR: Missing runtime libs"; exit 1) || true

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD pgrep hie_glomap || exit 1

CMD ["hie_glomap"]
