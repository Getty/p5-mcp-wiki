# syntax=docker/dockerfile:1
#
# Build context: the built distribution (dzil build), not the checkout.
#   dzil build && docker build -t mcp-wiki MCP-Wiki-*/
# dzil does this itself, for the image named by docker_image in dist.ini.
ARG PERL_VERSION=5.40-slim

# Build stage: what Git::Raw needs to compile
FROM perl:${PERL_VERSION} AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libssl-dev \
    pkg-config \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Dependencies first, in a layer that only changes with the metadata.
# --with-recommends brings the optional Git::Raw for the history tools.
COPY cpanfile META.json Makefile.PL ./
RUN cpanm --notest --installdeps --with-recommends .

COPY . .
RUN cpanm --notest .

# Runtime stage
FROM perl:${PERL_VERSION}

# The runtime libraries of Git::Raw
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3t64 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 appgroup && \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash appuser

# Everything cpanm installed: the modules and the mcp-wiki script
COPY --from=build /usr/local/lib/perl5/site_perl /usr/local/lib/perl5/site_perl
COPY --from=build /usr/local/bin/mcp-wiki /usr/local/bin/mcp-wiki

COPY --from=build /build/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# The wiki is the volume: mcp-wiki's default root "." is the working directory
RUN install -d -o 1000 -g 1000 /wiki
WORKDIR /wiki
USER appuser

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
