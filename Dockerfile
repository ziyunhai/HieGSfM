# syntax=docker/dockerfile:1

# 建议使用 Ubuntu 22.04，它的 libopenimageio-dev 原生包含 CMake Config 文件
# 如果你的显卡驱动支持，也可以直接将 11.8.0 改为 12.2.0，将 22.04 改为 24.04
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-11
ENV CXX=g++-11
ENV QT_XCB_GL_INTEGRATION=xcb_egl
ENV CCACHE_DIR=/workspace/build/.ccache
ENV CCACHE_BASEDIR=/workspace

WORKDIR /workspace

# 0、替换为阿里云apt源，国内构建加速
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 1、安装编译依赖 (参考官方 COLMAP Dockerfile 精简优化)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ccache cmake ninja-build build-essential git \
    python3-dev python3-pip python3-numpy python3-scipy \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libsuitesparse-dev libmetis-dev \
    libceres-dev libgoogle-glog-dev libgflags-dev libgtest-dev libgmock-dev \
    libopenimageio-dev openimageio-tools \
    libcurl4-openssl-dev libssl-dev libsqlite3-dev \
    qt6-base-dev libqt6opengl6-dev libqt6openglwidgets6-dev \
    libcgal-dev libomp-dev \
    && rm -rf /var/lib/apt/lists/*

# 2、【官方关键修复】解决 Ubuntu 的 openimageio CMake config 错误强依赖 OpenCV 头文件的问题
RUN mkdir -p /usr/include/opencv4

# 3、安装 Python 业务依赖
RUN pip3 install --no-cache-dir --upgrade pip && \
    pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 4、导入项目源码并准备第三方库
COPY . /workspace/project
WORKDIR /workspace/project

# 清理本地第三方目录，避免子模块冲突
RUN rm -rf /workspace/project/thirdparty/PoseLib /workspace/project/thirdparty/colmap

# 拉取第三方开源库源码
RUN git clone --recursive https://github.com/PoseLib/PoseLib.git /workspace/project/thirdparty/PoseLib
RUN git clone --recursive https://github.com/colmap/colmap.git /workspace/project/thirdparty/colmap

# 5、编译安装 PoseLib
RUN cd /workspace/project/thirdparty/PoseLib && \
    mkdir -p build && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON && \
    ninja install && \
    ldconfig

# 6、编译安装 COLMAP (移除了多余的 CMAKE_MODULE_PATH，现代系统可自动找到 OIIO)
RUN cd /workspace/project/thirdparty/colmap && \
    mkdir -p build/.ccache && cd build && \
    cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON \
        -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja install && \
    ldconfig

# 7、编译自身业务程序 hie_glomap
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
        -DCMAKE_CUDA_ARCHITECTURES="75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    ninja install && \
    ldconfig


# ======================== 运行时阶段 runtime ========================
# 使用对应的 runtime 镜像
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装基础运行时包 (参考官方，仅安装必要的 .so 运行时版本)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    libboost-program-options1.74.0 \
    libboost-filesystem1.74.0 \
    libboost-graph1.74.0 \
    libboost-system1.74.0 \
    libeigen3-dev \
    libceres1 \
    libgoogle-glog0v5 \
    libgflags2.2 \
    libopenimageio2.3 \
    libcurl4 libssl3 \
    libsqlite3-0 \
    libomp5 \
    libmetis5 \
    libqt6core6 libqt6gui6 libqt6widgets6 libqt6openglwidgets6 \
    libcgal16 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 【官方最佳实践】直接复制 builder 阶段安装到 /usr/local 的所有文件
# 这比手动用 ldd 抓取动态库安全、可靠得多，且能保留 CMake 配置文件
COPY --from=builder /usr/local/ /usr/local/

# 刷新动态链接缓存
RUN ldconfig

ENTRYPOINT ["hie_glomap"]
