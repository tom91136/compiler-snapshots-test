# Compiler snapshots


This repo/static site contains GCC and LLVM snapshot builds spaced one week apart using the ISO8601 week-based-year; commits that fail to generate a build are excluded.

Builds are compiled in CentOS 7 with glibc 2.17, most distros released after 2012 should be able to just download, untar, and use as-is without any external dependencies
The scripts and Dockerfile for generating the snapshots are available in the repo.

To browse and download snapshots by commit, use the static site: <>.  
 

## Machine and CI access

For machine access, use the GitHub Reference API to list all available snapshots tags:

    https://api.github.com/repos/$OWNER/$REPO/git/refs/tags

```json 
[
  {
    "ref": "refs/tags/gcc-8+2017-04-23Z+c7eb642",
    "node_id": "...",
    "url": "...",
    "object": "..."
  }
]
```

Once a tag is available, the download link to the snapshot uses the following format:

    https://github.com/$OWNER/$REPO/releases/download/$TAG/$TAG.tar.xz

Where `$TAG` is the tag name (e.g. `gcc-8.2017-04-23Z.c7eb642`).

The release notes can be received using the GitHub Release API:

    https://api.github.com/$OWNER/$REPO/snapshots/releases/tags/$TAG

**Note:** It is not recommended to use the Release API for listing releases because GitHub caps the
results to only 1k entries; many snapshots will be missing if enumerated this way.


## Testing

Testing a build locally: 

```shell
docker build --platform linux/$(arch) -t build_image .
docker run --rm -it  -v $PWD:/host/:rw,z  build_image /bin/bash
# Testing a specific build
[root@9fd6ab9e5ec7 /] /host/action_build_llvm.sh llvm-5.2017-07-30Z.397fe0b.x86_64
# Testing a hash directly (full hash required)
[root@9fd6ab9e5ec7 /] /host/action_build_llvm.sh 5408e6d64809fd035f781f10178765f724ac797b
# Bisect example, where GOOD1->BAD->GOOD2, based on actions outcome
[root@9fd6ab9e5ec7 /] REPO=gcc GOOD1=d656d82 BAD=1d10121 GOOD2=e64f7af /host/test_bisect.sh 
```

For cross building:

```shell
docker build --platform linux/$(arch)  -t build_image_cross -f Dockerfile.cross
docker run --rm -it -v $PWD:/host/:rw,z --security-opt label=disable --mount type=bind,src=/proc/sys/fs/binfmt_misc,target=/proc/sys/fs/binfmt_misc,ro build_image_cross /bin/bash
# Do a cross build
root@300f6b3dcc6b:/# CROSS_ARCH=riscv64  /host/action_build_llvm_cross.sh llvm-17.2023-05-28Z.53be2e0.riscv64
```

Alternatively with Apptainer/Singularity:

```shell
apptainer build --force build_image.sif Singularity.def
apptainer shell --compat --fakeroot --pwd=/ --bind "$PWD:/host:rw" build_image.sif
# Testing a specific build
Apptainer> /host/action_build_llvm.sh llvm-5.2017-07-30Z.397fe0b.x86_64
# Testing a hash directly (full hash required)
Apptainer> /host/action_build_llvm.sh 5408e6d64809fd035f781f10178765f724ac797b
# Bisect example, where GOOD1->BAD->GOOD2, based on actions outcome
Apptainer> REPO=gcc GOOD1=d656d82 BAD=1d10121 GOOD2=e64f7af /host/test_bisect.sh 

```