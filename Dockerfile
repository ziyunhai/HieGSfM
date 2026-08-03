# syntax=docker/dockerfile:1

FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-11
ENV CXX=g++-11
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace
WORKDIR /workspace

# 配置阿里云镜像源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装编译依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git \
    python3-dev python3-pip python3-numpy python3-scipy \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libopenimageio-dev openimageio-tools \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    qt6-base-dev libqt6opengl6-dev libcgal-dev libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# 修复 OIIO CMake 强依赖 OpenCV 头文件的问题
RUN mkdir -p /usr/include/opencv4

# 安装 Python 依赖
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 准备源码
COPY . /workspace/project
WORKDIR /workspace/project
RUN rm -rf /workspace/project/thirdparty/PoseLib /workspace/project/thirdparty/colmap
RUN git clone --recursive https://github.com/PoseLib/PoseLib.git /workspace/project/thirdparty/PoseLib
RUN git clone --recursive https://github.com/colmap/colmap.git /workspace/project/thirdparty/colmap

# 编译安装 PoseLib
RUN cd /workspace/project/thirdparty/PoseLib && mkdir -p build && cd build && \
    cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    ninja install && ldconfig

# 编译安装 COLMAP
RUN cd /workspace/project/thirdparty/colmap && mkdir -p build/.ccache && cd build && \
    cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCUDA_ENABLED=ON -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja install && ldconfig

# 编译安装业务程序 hie_glomap
RUN cd /workspace/project && mkdir -p build && cd build && \
    cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DFETCH_COLMAP=OFF -DFETCH_POSELIB=OFF -DTESTS_ENABLED=OFF -DASAN_ENABLED=OFF \
        -DCCACHE_ENABLED=ON -DCUDA_ENABLED=ON -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja install && ldconfig


# ======================== Runtime 阶段 ========================
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装运行时依赖 (已修正为 Ubuntu 22.04 实际包名，移除纯头文件库)
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository -y universe && apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 python3-pip \
    libboost-program-options1.74.0 libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-system1.74.0 \
    libceres2 libgoogle-glog0v5 libgflags2.2 libopenimageio2.2 \
    libcurl4 libssl3 libsqlite3-0 libomp5 libmetis5 \
    libqt6core6 libqt6gui6 libqt6widgets6 libqt6openglwidgets6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 复制编译产物
COPY --from=builder /usr/local/ /usr/local/

RUN ldconfig

ENTRYPOINT ["hie_glomap"]
