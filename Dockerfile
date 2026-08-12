# ===================================================================
# Base image
# ===================================================================
FROM buildpack-deps:24.04 AS base

# -------------------------------------------------------------------
# Environment
# -------------------------------------------------------------------
ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV DEBIAN_FRONTEND=noninteractive

ENV NB_USER=jovyan
ENV NB_UID=1000

ENV CONDA_DIR=/srv/conda
ENV DEFAULT_PATH=${PATH}

# Needed for webpdf notebook exports
ENV PLAYWRIGHT_BROWSERS_PATH=${CONDA_DIR}

# -------------------------------------------------------------------
# Locale + user
# -------------------------------------------------------------------
RUN apt-get -qq update --yes && \
    apt-get -qq install --yes locales && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

RUN if getent group ${NB_UID}; then \
      GROUP_1000="$(getent group ${NB_UID} | cut -d: -f1)"; \
      if [ "$GROUP_1000" != "$NB_USER" ]; then \
        groupmod --new-name ${NB_USER} "$GROUP_1000"; \
      fi; \
    else \
      groupadd --gid ${NB_UID} ${NB_USER}; \
    fi
RUN if id ${NB_UID}; then \
      USER_1000="$(id ${NB_UID} -un)"; \
      if [ "$USER_1000" != "$NB_USER" ]; then \
        usermod --home "/home/$NB_USER" --login "$NB_USER" --move-home "$USER_1000"; \
      fi; \
    else \
      useradd \
        --comment "Default user" \
        --create-home \
        --gid ${NB_UID} \
        --no-log-init \
        --shell /bin/bash \
        --uid ${NB_UID} \
        ${NB_USER}; \
    fi

# -------------------------------------------------------------------
# Man pages
# -------------------------------------------------------------------
RUN sed -i '/usr.share.man/s/^/#/' /etc/dpkg/dpkg.cfg.d/excludes
RUN apt --reinstall install coreutils

# -------------------------------------------------------------------
# System packages
# -------------------------------------------------------------------
COPY apt.txt /tmp/apt.txt
RUN apt-get -qq update --yes && \
    apt-get -qq install --yes --no-install-recommends \
        $(grep -v ^# /tmp/apt.txt) && \
    apt-get -qq purge && \
    apt-get -qq clean && \
    rm -rf /var/lib/apt/lists/*

# Remove diverted man binary
RUN if [ "$(dpkg-divert --truename /usr/bin/man)" = "/usr/bin/man.REAL" ]; then \
        rm -f /usr/bin/man; \
        dpkg-divert --quiet --remove --rename /usr/bin/man; \
    fi

RUN mandb -c

# ===================================================================
# Solve the environment with pixi, then materialize it with micromamba
# ===================================================================
# pixi.toml is the source of truth for this environment (conda deps in
# [dependencies], pip-only packages in [pypi-dependencies]) and is solved
# directly -- no conversion step. pixi never touches /srv/conda and is not
# present in the final image; it only computes what to install.
# micromamba does the actual, no-solve install of pixi's already-resolved
# package list -- also build-time only, not shipped in the final image.
# The full Miniforge install below is what actually ships, so end users get
# real mamba/conda for their own runtime package management, unchanged from
# base-python-image.
FROM base AS solver

USER root
RUN curl -fsSL "https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-linux-64" \
        -o /usr/local/bin/micromamba && \
    chmod +x /usr/local/bin/micromamba
RUN curl -fsSL https://pixi.sh/install.sh | PIXI_HOME=/opt/pixi sh
ENV PATH=/opt/pixi/bin:$PATH

USER ${NB_USER}
WORKDIR /tmp/solve
COPY --chown=${NB_USER}:${NB_USER} pixi.toml scripts/pixi-pypi-requirements.py ./

# conda-explicit-spec is pixi's native, checksummed explicit-install export;
# --ignore-pypi-errors is required because it can't represent PyPI packages
# (see https://github.com/jupyterhub/repo2docker/issues/1339), which is why
# pixi-pypi-requirements.py separately extracts those from `pixi list --json`.
RUN pixi install && \
    pixi workspace export conda-explicit-spec --platform linux-64 --ignore-pypi-errors /tmp/solve-out && \
    mv /tmp/solve-out/*_conda_spec.txt /tmp/explicit.txt && \
    pixi list --json | python3 pixi-pypi-requirements.py > /tmp/pip-requirements.txt

# ===================================================================
# Build /srv/conda and notebook environment
# ===================================================================
FROM base AS srv-conda

USER root
RUN install -d -o ${NB_USER} -g ${NB_USER} ${CONDA_DIR}

USER ${NB_USER}

# Install Miniforge (this is what actually ships -- see note above)
COPY --chown=${NB_USER}:${NB_USER} install-miniforge.bash /tmp/install-miniforge.bash
RUN bash /tmp/install-miniforge.bash

ENV PATH=${CONDA_DIR}/bin:$PATH

# -------------------------------------------------------------------
# Create the 'notebook' environment from pixi's pre-solved package list.
# micromamba installs the @EXPLICIT list with no solving at all -- pixi
# already found a mutually-compatible set, so this is just downloads +
# linking, regardless of how large or interdependent the package list is.
# -------------------------------------------------------------------
COPY --from=solver --chown=${NB_USER}:${NB_USER} /usr/local/bin/micromamba /tmp/micromamba
COPY --from=solver --chown=${NB_USER}:${NB_USER} /tmp/explicit.txt /tmp/pip-requirements.txt /tmp/
RUN chmod +x /tmp/micromamba && \
    /tmp/micromamba create -y -p ${CONDA_DIR}/envs/notebook --file /tmp/explicit.txt

# Use notebook env by default
ENV PATH=${CONDA_DIR}/envs/notebook/bin:$PATH

# pixi resolves [pypi-dependencies] but only installs them into its own
# throwaway solver environment; install pixi's resolved versions into the
# real notebook env here.
RUN pip install --no-cache-dir -r /tmp/pip-requirements.txt

RUN mamba clean -afy && \
    rm -f /tmp/micromamba /tmp/explicit.txt /tmp/pip-requirements.txt

# -------------------------------------------------------------------
# Playwright (Chromium)
# -------------------------------------------------------------------
RUN playwright install chromium

# Verify installation
RUN mamba list -n notebook

# ===================================================================
# Final image
# ===================================================================
FROM base AS final

USER root

COPY --from=srv-conda /srv/conda /srv/conda
RUN chown -R ${NB_USER}:${NB_USER} /srv/conda

USER ${NB_USER}

ENV PATH=${CONDA_DIR}/envs/notebook/bin:${CONDA_DIR}/bin:${DEFAULT_PATH}

# Cleanup temp files
USER root
RUN rm -rf /tmp/*
