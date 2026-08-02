# ======================== 构建阶段 builder ========================
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu20.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CC=gcc-9
ENV CXX=g++-9
WORKDIR /workspace

# 1、安装kitware官方新版CMake
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget gnupg ca-certificates \
    && wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/kitware-archive-keyring.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ focal main' > /etc/apt/sources.list.d/kitware.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

# 2、安装全套编译依赖（开启universe保证所有开发包可用）
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository universe \
    && add-apt-repository multiverse \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential ninja-build git pkg-config ccache vim \
    python3-dev python3-pip python3-numpy python3-scipy \
    gcc-9 g++-9 \
    libboost-program-options-dev libboost-filesystem-dev libboost-graph-dev \
    libboost-regex-dev libboost-system-dev libboost-test-dev libboost-serialization-dev \
    libeigen3-dev libsuitesparse-dev libatlas-base-dev libblas-dev liblapack-dev libmetis-dev \
    libceres-dev libfreeimage-dev libflann-dev libjasper-dev libgoogle-glog-dev libgflags-dev libglew-dev \
    qtbase5-dev libqt5opengl5-dev libcgal-dev libcgal-qt5-dev libxml2-dev libomp-dev libsqlite3-dev libgtest-dev \
    autoconf automake libtool flex bison \
    && rm -rf /var/lib/apt/lists/*

# 3、安装Python依赖
RUN pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir scikit-learn scipy numpy progressbar2

# 4、导入项目源码
COPY . /workspace/project

# 清空thirdparty，避免CI残留子模块目录冲突
RUN rm -rf /workspace/project/thirdparty/PoseLib /workspace/project/thirdparty/colmap

# 拉取第三方源码
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
    && make install

# 编译安装 COLMAP
RUN cd /workspace/project/thirdparty/colmap \
    && mkdir build && cd build \
    && cmake .. -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_ENABLED=ON \
        -DGUI_ENABLED=ON \
        -DCMAKE_CUDA_ARCHITECTURES="35;50;52;60;61;70;75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    && ninja -j$(nproc) \
    && ninja install

# 编译业务主项目
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
        -DCMAKE_CUDA_ARCHITECTURES="35;50;52;60;61;70;75;80;86" \
        -DCMAKE_CUDA_FLAGS="-Wno-deprecated-declarations" \
    && ninja -j$(nproc) \
    && ninja install

RUN ldconfig

# ======================== 运行时阶段 runtime ========================
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/usr/local/bin:$PATH
WORKDIR /data

# 关键：runtime开启universe、multiverse源，解决libjasper-dev/libcgal-dev找不到
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository universe \
    && add-apt-repository multiverse \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    libboost-program-options1.71.0 libboost-filesystem1.71.0 libboost-graph1.71.0 \
    libboost-regex1.71.0 libboost-system1.71.0 libboost-serialization1.71.0 \
    libgomp1 libblas3 liblapack3 libatlas3-base libceres1 libfreeimage3 \
    libflann-dev libjasper-dev libgoogle-glog0v5 libgflags2.2 libglew2.1 \
    libqt5opengl5 libqt5widgets5 libcgal-dev libxml2 libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# 从构建阶段拷贝编译产物：二进制、库文件、配置、Python环境
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/share /usr/local/share

COPY --from=builder /usr/local/lib/python3.8/dist-packages /usr/local/lib/python3.8/dist-packages
COPY --from=builder /usr/bin/python3 /usr/bin/python3
COPY --from=builder /usr/bin/pip3 /usr/bin/pip3

# 刷新动态链接器缓存
RUN ldconfig

# 默认启动命令
ENTRYPOINT ["hie_glomap"]
