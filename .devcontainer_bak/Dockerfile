FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Create isolated workspace directory
RUN mkdir -p /workspaces && chown vscode:vscode /workspaces

# Install additional security tools for auditing
RUN apt-get update && apt-get install -y --no-install-recommends \
    auditd \
    bzip2 \
    && rm -rf /var/lib/apt/lists/*

# Install restic
RUN curl -L https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_linux_amd64.bz2 | bunzip2 > /usr/local/bin/restic \
    && chmod +x /usr/local/bin/restic

# Set restrictive umask
RUN echo "umask 027" >> /etc/profile

# Non-root user (vscode) is used by default
USER vscode

WORKDIR /workspaces
