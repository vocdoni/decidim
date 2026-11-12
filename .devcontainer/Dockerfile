ARG RUBY_VERSION=3.4.7
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

RUN wget -q -O /tmp/google-chrome-key.pub https://dl-ssl.google.com/linux/linux_signing_key.pub \
    && sudo gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg /tmp/google-chrome-key.pub \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list \
    && sudo apt-get update \
    # libvips42 is required by ruby-vips, which Decidim's Active Storage
    # variants load at boot. Without it the application does not start at all,
    # and the error names `vips.so.42` rather than the missing package.
    && sudo apt-get install -y google-chrome-stable libicu-dev libvips42 \
    && sudo rm -rf /var/lib/apt/lists/* /tmp/google-chrome-key.pub

# Node is NOT in the ruby devcontainer base image, and Shakapacker shells out to
# `npm exec webpack` -- without it `bin/shakapacker` dies with
# `No such file or directory - npm (Errno::ENOENT)`, which names npm rather than
# the missing toolchain. Installing it here rather than by hand in the running
# container, because `docker compose up -d` recreates the container and discards
# anything installed into it interactively (the same way libvips42 went missing).
# Version tracks /.node-version.
ARG NODE_VERSION=24.18.0
RUN curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && sudo tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
    && rm -f /tmp/node.tar.xz \
    && node --version && npm --version

ENV BINDING="0.0.0.0"
