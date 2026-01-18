FROM plantuml/plantuml:1.2026.0

# Add CJK fonts so PlantUML can render Chinese text in generated images.
# Base image: Ubuntu 22.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-noto-cjk \
        fonts-noto-cjk-extra \
        fonts-wqy-zenhei \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f
