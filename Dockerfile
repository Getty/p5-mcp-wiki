# syntax=docker/dockerfile:1
ARG ALPINE_VERSION=3.19
ARG PERL_VERSION=5.38

# Build stage
FROM perl:${PERL_VERSION}-alpine AS build

RUN apk add --no-cache \
    build-base \
    linux-headers \
    openssl-dev \
    zlib-dev

WORKDIR /build

COPY cpanfile .
RUN cpanm --installdeps --cpanfile cpanfile --notest --verbose || true

COPY . .

RUN cpanm . --notest || true

# Runtime stage
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
    perl \
    openssl \
    zlib \
    libcrypto3 \
    zlib-libs

# Create non-root user
RUN addgroup -g 1000 -S appgroup && \
    adduser -u 1000 -S appuser -G appgroup

WORKDIR /home/appuser

# Copy pre-installed modules from build
COPY --from=build /usr/local/lib/perl5/site_perl /usr/local/lib/perl5/site_perl
COPY --from=build /usr/local/bin/mcp-wiki /usr/local/bin/mcp-wiki

# Copy wiki root (empty, for data persistence)
RUN mkdir -p /home/appuser/wiki && chown -R appuser:appgroup /home/appuser

USER appuser

ENV PERL5LIB=/usr/local/lib/perl5/site_perl
ENV MCP_WIKI_ROOT=/home/appuser/wiki

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/mcp-wiki"]
CMD ["--wiki-root", "/home/appuser/wiki"]