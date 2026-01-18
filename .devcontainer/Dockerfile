FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Create isolated workspace directory
RUN mkdir -p /workspaces && chown vscode:vscode /workspaces

# Install additional security tools for auditing
RUN apt-get update && apt-get install -y --no-install-recommends \
    auditd \
    && rm -rf /var/lib/apt/lists/*

# Set restrictive umask
RUN echo "umask 027" >> /etc/profile

# Non-root user (vscode) is used by default
USER vscode

WORKDIR /workspaces
