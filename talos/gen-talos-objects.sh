talosctl gen secrets -o talos/secrets.yaml
talosctl gen config --with-secrets talos/secrets.yaml strudelnetes https://10.69.60.10:6443 --config-patch @patch.yaml --output ./talos --force
