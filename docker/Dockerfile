# Everything the kit builds, in one place. Nothing depends on this
# particular compiler: the loader enters the kernel Image directly.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-arm-linux-gnueabihf \
        binutils-arm-linux-gnueabihf \
        libc6-dev-armhf-cross \
        gcc-arm-none-eabi \
        binutils-arm-none-eabi \
        device-tree-compiler \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        python3 \
        python3-capstone \
        python3-pip \
        unzip \
        curl \
        file \
        cpio \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Cascadia's img3decrypt.py imports Crypto; Ubuntu's package is Cryptodome.
RUN pip3 install --no-cache-dir pycryptodome==3.20.0

ENV ARCH=arm
ENV CROSS_COMPILE=arm-linux-gnueabihf-

WORKDIR /work
