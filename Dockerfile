# ======================== 构建阶段 builder ========================
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-9
ENV CXX=g++-9
WORKDIR /workspace

# ccache 配置（加速增量构建）
ENV CCACHE_DIR=/workspace/ccache
ENV CCACHE_BASEDIR=/workspace

# 0、替换为阿里云apt源，国内构建加速
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    find /etc/apt/sources.list.d/ -name "*.list" -exec sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' {} \; && \
    find /etc/apt/sources.list.d/ -name "*.list" -exec sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' {} \;

# 1、安装Kitware官方新版CMake
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget gnupg ca-certificates \
    && wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ focal main' > /etc/apt/sources.list.d/kitware.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

# 2、安装全套编译开发依赖
#    - OpenImageIO：COLMAP 4.x 强制依赖
#    - curl/ssl：COLMAP 下载功能必需
#    - autotools/bison/flex：igraph 编译依赖
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y universe \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential ninja-build git pkg-config ccache \
    python3-dev python3-pip python3-numpy python3-scipy \
    gcc-9 g++-9 \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev \
    libboost-regex-dev libboost-system-dev libboost-test-dev libboost-serialization-dev \
    libeigen3-dev libsuitesparse-dev libatlas-base-dev libblas-dev liblapack-dev libmetis-dev \
    libceres-dev libfreeimage-dev libflann-dev libgoogle-glog-dev libgflags-dev libglew-dev \
    qtbase5-dev libqt5opengl5-dev libcgal-dev libcgal-qt5-dev libxml2-dev libomp-dev libsqlite3-dev libgtest-dev \
    autoconf automake libtool flex bison \
    libopenimageio-dev openimageio-tools \
    libcurl4-openssl-dev libssl-dev \
    && mkdir -p /usr/include/opencv4 \
    && dpkg -L libopenimageio-dev | grep -E '\.cmake$' || true \
    && rm -rf /var/lib/apt/lists/*

# 3、安装Python业务依赖
RUN pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 4、导入项目源码
COPY . /workspace/project

# 清理本地第三方目录，避免子模块冲突
RUN rm -rf /workspace/project/thirdparty/PoseLib /workspace/project/thirdparty/colmap

# 拉取第三方开源库源码
RUN git clone --recursive https://github.com/PoseLib/PoseLib.git /workspace/project/thirdparty/PoseLib
RUN git clone --recursive https://github.com/colmap/colmap.git /workspace/project/thirdparty/colmap

# 编译安装 PoseLib
RUN cd /workspace/project/thirdparty/PoseLib \
    && mkdir build && cd build \
    && cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    && make -j$(nproc) \
    && make install \
    && ldconfig


# 编译安装 COLMAP
# - CUDA 架构精简为 75(T4/V100)、80(A100/A30)、86(RTX30/40系)
# - CMAKE_PREFIX_PATH 兜底指定 OpenImageIO CMake 路径
RUN cd /workspace/project/thirdparty/colmap \
    && mkdir -p build/.ccache \
    && cd build \
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON \
        -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_PREFIX_PATH="/usr/lib/x86_64-linux-gnu/cmake/OpenImageIO;${CMAKE_PREFIX_PATH}" \
    && ninja -j$(nproc) \
    && ninja install \
    && ldconfig

# 编译自身业务程序 hie_glomap
RUN cd /workspace/project \
    && mkdir build && cd build \
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DFETCH_COLMAP=OFF \
        -DFETCH_POSELIB=OFF \
        -DTESTS_ENABLED=OFF \
        -DASAN_ENABLED=OFF \
        -DCCACHE_ENABLED=ON \
        -DCUDA_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    && ninja -j$(nproc) \
    && ninja install \
    && ldconfig

# 收集程序运行依赖的全部系统动态库，打包存放
RUN mkdir -p /tmp/deps_lib && \
    ldd /usr/local/bin/hie_glomap /usr/local/bin/colmap \
        | awk '/=> \/lib|=> \/usr\/lib/ {print $3}' \
        | sort -u \
        | xargs cp -t /tmp/deps_lib/ 2>/dev/null || true

# ======================== 运行时阶段 runtime ========================
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

# 阿里云apt源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装基础运行时包
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
    libgoogle-glog0v5 \
    libgflags2.2 \
    libglew2.1 \
    libqt5opengl5 \
    libqt5widgets5 \
    libxml2 \
    libsqlite3-0 \
    libopenimageio2.1 \
    libcurl4 \
    libssl1.1 \
    && rm -rf /var/lib/apt/lists/*

# 1、复制编译好的二进制文件、第三方库
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/share /usr/local/share

# 2、复制builder收集好的所有系统动态库
COPY --from=builder /tmp/deps_lib/* /usr/lib/x86_64-linux-gnu/

# 3、复制Python运行环境
COPY --from=builder /usr/local/lib/python3.8/dist-packages /usr/local/lib/python3.8/dist-packages
COPY --from=builder /usr/bin/python3 /usr/bin/python3
COPY --from=builder /usr/bin/pip3 /usr/bin/pip3

# 刷新动态链接缓存
RUN ldconfig

ENTRYPOINT ["hie_glomap"]
