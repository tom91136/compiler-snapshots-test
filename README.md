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