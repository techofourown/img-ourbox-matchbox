#!/usr/bin/env bash
set -euo pipefail

systemctl enable ourbox-bootstrap.service
# DO NOT enable k3s here. Bootstrap enables it only after hydration prep.
