# github-watchdog (linux): route non-git tools through the local GitHub proxy,
# keep LAN + Chinese package/code mirrors DIRECT (so pip/apt/HF stay fast).
# Only login shells pick this up. git has its own scoped proxy already.
_gh_proxy="http://127.0.0.1:8180"
export http_proxy="$_gh_proxy"
export https_proxy="$_gh_proxy"
export HTTP_PROXY="$_gh_proxy"
export HTTPS_PROXY="$_gh_proxy"
export no_proxy="localhost,127.0.0.1,::1,172.25.0.0/16,10.0.0.0/8,192.168.0.0/16,.local,hf-mirror.com,.tuna.tsinghua.edu.cn,mirrors.ustc.edu.cn,mirrors.aliyun.com,mirrors.cloud.aliyuncs.com,pypi.tuna.tsinghua.edu.cn,pypi.org,files.pythonhosted.org,deb.debian.org,archive.ubuntu.com,security.ubuntu.com,.ubuntu.com,gh-proxy.com,ghproxy.net,ghproxy.cn,hf.co"
export NO_PROXY="$no_proxy"
