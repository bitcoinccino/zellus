# Pin npm packages by running ./bin/importmap
#
# This app currently loads its JavaScript inline in views rather than through
# importmap pins, so there are no CDN-pinned packages here. The file exists so
# the importmap CLI (e.g. `bin/importmap audit` in CI) has a manifest to read.

pin "application"
