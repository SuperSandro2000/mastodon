FROM ubuntu:19.04 as build-dep

# Use bash for the shell
SHELL ["bash", "-c"]

# Install Node
RUN	echo "Etc/UTC" > /etc/localtime && \
	apt update && \
	apt -y install wget && \
	wget -O - https://deb.nodesource.com/setup_8.x | bash - && \
	apt install -y nodejs npm

# Install ruby
ENV RUBY_VER="2.6.1"
RUN apt update && \
	apt -y install build-essential \
		bison libyaml-dev libgdbm-dev libreadline-dev libjemalloc-dev \
		libncurses5-dev libffi-dev zlib1g-dev libssl-dev && \
	cd ~ && \
	wget https://cache.ruby-lang.org/pub/ruby/${RUBY_VER%.*}/ruby-$RUBY_VER.tar.gz && \
	tar xf ruby-$RUBY_VER.tar.gz && \
	cd ruby-$RUBY_VER && \
	./configure --prefix=/opt/ruby \
	  --with-jemalloc \
	  --with-shared \
	  --disable-install-doc && \
	make -j$(nproc) > /dev/null && \
	make install

ENV PATH="${PATH}:/opt/ruby/bin"

RUN npm install -g yarn && \
	gem install bundler && \
	apt update && \
	apt -y install git libicu-dev libidn11-dev \
	libpq-dev libprotobuf-dev protobuf-compiler

COPY Gemfile* package.json yarn.lock /opt/mastodon/

RUN cd /opt/mastodon && \
	bundle install -j$(nproc) --deployment --without development test && \
	yarn install --pure-lockfile

FROM ubuntu:19.04

# Copy over all the langs needed for runtime
COPY --from=build-dep /opt/ruby /opt/ruby

# Add more PATHs to the PATH
ENV PATH="${PATH}:/opt/ruby/bin:/opt/mastodon/bin"

# Create the mastodon user
ARG UID=991
ARG GID=991
RUN apt update && \
	echo "Etc/UTC" > /etc/localtime && \
	apt install -y whois wget && \
	addgroup --gid $GID mastodon && \
	useradd -m -u $UID -g $GID -d /opt/mastodon mastodon && \
	echo "mastodon:`head /dev/urandom | tr -dc A-Za-z0-9 | head -c 24 | mkpasswd -s -m sha-256`" | chpasswd

# Install mastodon runtime deps
RUN wget -O - https://deb.nodesource.com/setup_8.x | bash - && \
		apt -y --no-install-recommends install \
	  libssl1.1 libpq5 imagemagick ffmpeg nodejs npm libjemalloc-dev \
	  libicu63 libprotobuf17 libidn11 libyaml-0-2 gcc \
	  file ca-certificates tzdata libreadline8 && \
	ln -s /opt/mastodon /mastodon && \
	npm install -g yarn && \
	gem install bundler && \
	rm -rf /var/cache && \
	rm -rf /var/lib/apt/lists/*

# Add tini
ENV TINI_VERSION="0.18.0"
ENV TINI_SUM="12d20136605531b09a2c2dac02ccee85e1b874eb322ef6baf7561cd93f93c855"
ADD https://github.com/krallin/tini/releases/download/v${TINI_VERSION}/tini /tini
RUN echo "$TINI_SUM tini" | sha256sum -c -
RUN chmod +x /tini

# Copy over mastodon source, and dependencies from building, and set permissions
COPY --chown=mastodon:mastodon . /opt/mastodon
COPY --from=build-dep --chown=mastodon:mastodon /opt/mastodon /opt/mastodon

# Run mastodon services in prod mode
ENV RAILS_ENV="production"
ENV NODE_ENV="production"

# Tell rails to serve static files
ENV RAILS_SERVE_STATIC_FILES="true"

# Set the run user
USER mastodon

# Precompile assets
RUN cd ~ && \
	OTP_SECRET=precompile_placeholder SECRET_KEY_BASE=precompile_placeholder rails assets:precompile && \
	yarn cache clean

# Set the work dir and the container entry point
WORKDIR /opt/mastodon
ENTRYPOINT ["/tini", "--"]
