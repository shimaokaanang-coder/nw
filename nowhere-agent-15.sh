#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Nowhere Agent v14 节点管理脚本 (Xboard 插件配套)
# 支持：安装 / 查看拉取用户 / 查看日志 / 启停服务 / 卸载
# 默认 tls=1（IP模式，无需证书）
# ============================================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
title() { echo -e "${CYAN}$*${NC}"; }

# 路径常量
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/nowhere-agent"
SERVICE_NAME="nowhere-agent"
NOWHERE_BIN="${INSTALL_DIR}/nowhere"
AGENT_BIN="${INSTALL_DIR}/nowhere-agent"
CONFIG_FILE="${CONFIG_DIR}/config.env"
GO_VERSION="1.23.4"
WORK_DIR="/tmp/nowhere-build-$$"

# 默认参数（安装时使用）
PANEL_URL=""
NODE_TOKEN=""
NODE_ID=""
NODE_NAME="Nowhere"
PORT_START=20000
PORT_END=30000
POLL_INTERVAL=20
NOWHERE_VERSION="latest"
# Morph TCP 客户端策略：默认 full8（8-bit random）；只影响本机作为 Morph TCP 客户端发起的连接。
# Portal 入站服务端不解析 prelude 内容。
NOW_MORPH_TCP_PRELUDE="full8"

# ====================== 工具函数 ======================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本（sudo bash $0）"
    exit 1
  fi
}

detect_arch() {
  case $(uname -m) in
    x86_64|amd64) ARCH=amd64; GOARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64; GOARCH=arm64 ;;
    *) error "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    return 0
  fi
  return 1
}

service_exists() {
  systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1
}

pause() {
  echo
  read -rp "按回车键返回菜单..."
}

# ====================== 菜单 ======================
show_menu() {
  clear
  title "================================================"
  title "     Nowhere Agent v15 密钥修复版 (XBoard)"
  title "================================================"
  echo
  if load_config; then
    echo -e "  当前节点状态: ${GREEN}已安装${NC}"
    echo -e "  面板地址    : ${BLUE}${PANEL_URL:-未设置}${NC}"
    echo -e "  节点 ID     : ${BLUE}${NODE_ID:-未设置}${NC}"
    echo -e "  节点名称    : ${BLUE}${NODE_NAME:-Nowhere}${NC}"
    echo -e "  端口池      : ${BLUE}${PORT_START:-20000}-${PORT_END:-30000}${NC}"
    echo -e "  轮询间隔    : ${BLUE}${POLL_INTERVAL:-20}s${NC}"
    echo -e "  Morph Prelude: ${BLUE}${NOW_MORPH_TCP_PRELUDE:-full8}${NC}"
    # 每次打开菜单都现场探测一次，而不是用装机时的旧变量——避免"装的时候能用，
    # 之后系统更新/换内核导致失效"这种情况被一直显示成"可用"
    if command -v iptables >/dev/null 2>&1 && iptables -S >/dev/null 2>&1; then
      echo -e "  流量统计    : ${GREEN}IPv4/IPv6 分方向计数已配置${NC}"
    else
      echo -e "  流量统计    : ${YELLOW}iptables 不可用（流量统计不可用）${NC}"
    fi
  else
    echo -e "  当前节点状态: ${YELLOW}未安装${NC}"
  fi
  echo
  echo "  1) 安装 / 重新安装节点"
  echo "  2) 查看服务状态"
  echo "  3) 查看实时日志"
  echo "  4) 查看最近拉取的用户列表（如果 Agent 已实现）"
  echo "  5) 启动服务"
  echo "  6) 停止服务"
  echo "  7) 重启服务"
  echo "  8) 查看配置文件"
  echo "  9) 卸载节点"
  echo "  0) 退出"
  echo
  title "================================================"
  echo
}

# ====================== 安装相关 ======================

# 包管理器探测结果缓存，避免每次都重新判断
PKG_MGR=""
detect_pkg_mgr() {
  [[ -n "$PKG_MGR" ]] && return 0
  if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
  elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"
  else PKG_MGR="unknown"
  fi
}

# 命令名 -> 各包管理器下对应的包名（不用关联数组，保证在老版本 bash 下也能跑）
pkg_name_for() {
  local cmd="$1"
  case "${PKG_MGR}:${cmd}" in
    apt:curl)             echo "curl" ;;
    apt:tar)              echo "tar" ;;
    apt:fuser)            echo "psmisc" ;;
    apt:iptables)         echo "iptables" ;;
    yum:curl|dnf:curl)         echo "curl" ;;
    yum:tar|dnf:tar)           echo "tar" ;;
    yum:fuser|dnf:fuser)       echo "psmisc" ;;
    yum:iptables|dnf:iptables) echo "iptables" ;;
    apk:curl)             echo "curl" ;;
    apk:tar)              echo "tar" ;;
    apk:fuser)            echo "psmisc" ;;
    apk:iptables)         echo "iptables" ;;
    pacman:curl)          echo "curl" ;;
    pacman:tar)           echo "tar" ;;
    pacman:fuser)         echo "psmisc" ;;
    pacman:iptables)      echo "iptables" ;;
    *) echo "" ;;
  esac
}

pkg_install() {
  local pkg="$1"
  detect_pkg_mgr
  case "$PKG_MGR" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 ;;
    yum)    yum install -y -q "$pkg" >/dev/null 2>&1 ;;
    dnf)    dnf install -y -q "$pkg" >/dev/null 2>&1 ;;
    apk)    apk add --no-cache "$pkg" >/dev/null 2>&1 ;;
    pacman) pacman -S --noconfirm --needed "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# 通用：检测命令是否存在，不存在则按包名自动安装，装完再次验证。
# 用法: ensure_cmd <命令名> [自定义包名，留空则用 pkg_name_for 自动映射]
# 返回 0 = 命令可用（本来就有，或装完验证通过）；返回 1 = 装完仍不可用
ensure_cmd() {
  local cmd="$1" pkg="${2:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  warn "未检测到命令: ${cmd}，尝试自动安装..."
  detect_pkg_mgr
  [[ -z "$pkg" ]] && pkg=$(pkg_name_for "$cmd")
  if [[ -z "$pkg" ]]; then
    error "无法确定 ${cmd} 对应的安装包（包管理器未知或映射缺失），请手动安装后重试"
    return 1
  fi
  if ! pkg_install "$pkg"; then
    error "自动安装 ${pkg} 失败（网络问题 / 源不可用 / 包名在该系统上不同）"
    return 1
  fi
  # 装完必须再验证一次，不能装完就假设成功
  if command -v "$cmd" >/dev/null 2>&1; then
    info "${cmd} 安装成功"
    return 0
  else
    error "已尝试安装 ${pkg}，但仍未检测到 ${cmd}，请手动排查"
    return 1
  fi
}

# iptables 专用检测：光有二进制不够，必须实际验证内核支持（OpenVZ/部分容器环境
# 常见"命令存在但内核不支持"的情况），必要时尝试加载内核模块后重试一次。
# 结果写入全局变量 IPTABLES_WORKING，供安装流程和 config 摘要使用。
IPTABLES_WORKING=0
ensure_iptables() {
  info "检测 iptables..."
  if ! ensure_cmd "iptables"; then
    warn "iptables 不可用，节点仍会安装，但无法精确统计流量（上报流量会恒为 0）"
    IPTABLES_WORKING=0
    return 0
  fi

  if iptables -S >/dev/null 2>&1; then
    IPTABLES_WORKING=1
    info "iptables 功能验证通过"
    return 0
  fi

  warn "iptables 命令存在但无法执行，尝试加载内核模块..."
  modprobe ip_tables 2>/dev/null || true
  modprobe iptable_filter 2>/dev/null || true

  if iptables -S >/dev/null 2>&1; then
    IPTABLES_WORKING=1
    info "加载内核模块后 iptables 验证通过"
  else
    IPTABLES_WORKING=0
    warn "=========================================="
    warn "此服务器内核不支持 iptables（常见于 OpenVZ / 部分受限容器）"
    warn "节点仍会正常安装运行，但流量统计功能不可用，上报流量会持续为 0"
    warn "=========================================="
  fi
}

install_deps() {
  info "安装系统依赖..."
  detect_pkg_mgr
  # 注：wget/git/gcc/make/iproute2/unzip 此前虽在安装列表中，但脚本和 Agent
  # 实际运行全程未调用（下载走 curl、编译已关闭 CGO 且不联网拉包、无 zip 文件
  # 需要解压、ss/ip 命令从未被调用），故不再安装，减少体积和安装耗时。
  # iptables 是流量统计的核心依赖，此前完全没有被列入安装列表，是"没有 iptables、
  # 没有上报流量"的根本原因之一，这里补上；kmod 用于后续 modprobe 内核模块。
  case "$PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq curl tar ca-certificates psmisc iptables kmod >/dev/null
      ;;
    yum)
      yum install -y -q curl tar ca-certificates psmisc iptables kmod >/dev/null 2>&1 \
        || yum install -y -q curl tar ca-certificates psmisc iptables-nft kmod >/dev/null
      ;;
    dnf)
      dnf install -y -q curl tar ca-certificates psmisc iptables kmod >/dev/null 2>&1 \
        || dnf install -y -q curl tar ca-certificates psmisc iptables-nft kmod >/dev/null
      ;;
    apk)
      apk add --no-cache curl tar ca-certificates psmisc iptables kmod >/dev/null
      ;;
    pacman)
      pacman -Sy --noconfirm --needed curl tar ca-certificates psmisc iptables >/dev/null
      ;;
    *)
      warn "未知包管理器，请确保已安装 curl tar psmisc(fuser) iptables"
      ;;
  esac
}

install_go() {
  if command -v go >/dev/null 2>&1; then
    local ver
    ver=$(go version | grep -oP 'go\d+\.\d+' || true)
    if [[ -n "$ver" ]]; then
      info "已检测到 Go: $(go version)"
      return 0
    fi
  fi

  info "安装 Go ${GO_VERSION}..."
  local go_tar="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
  curl -fsSL "https://go.dev/dl/${go_tar}" -o "/tmp/${go_tar}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${go_tar}"
  rm -f "/tmp/${go_tar}"
  export PATH=/usr/local/go/bin:$PATH
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/go.sh
  info "Go 安装完成: $(go version)"
}

install_nowhere() {
  info "下载 Nowhere 二进制..."

  # 官方资源命名：nowhere-x86_64-unknown-linux-gnu.tar.gz / musl / aarch64
  local arch_name asset tag url tmp bin
  case "$(uname -m)" in
    x86_64|amd64) arch_name="x86_64" ;;
    aarch64|arm64) arch_name="aarch64" ;;
    *) error "不支持的架构: $(uname -m)"; return 1 ;;
  esac

  # musl 是静态链接，对任何发行版 glibc 版本都兼容，直接优先用它，
  # 不再先探测/尝试 gnu 版本（很多主流发行版如 Debian 12/Ubuntu 22.04 glibc 版本都不够新，
  # 每次都要先失败一次才 fallback，纯浪费时间和带宽）
  if [[ "$NOWHERE_VERSION" == "latest" || -z "$NOWHERE_VERSION" ]]; then
    tag=$(curl -fsSL "https://api.github.com/repos/NodePassProject/Nowhere/releases/latest" 2>/dev/null \
      | grep -oE '"tag_name":\s*"[^"]+"' | head -1 | sed 's/.*"tag_name":\s*"\([^"]*\)".*/\1/')
    tag=${tag:-v3.0.0}
  else
    tag="$NOWHERE_VERSION"
  fi
  info "版本: $tag"
  # 不锁定具体版本：正式版发布后，GitHub releases/latest 会自动跟随正式版。
  # v2.1 Morph 与 2.0.x 不兼容，生产环境启用 Morph 时需确保整条 Morph 链路一起升级。

  # 依次尝试 musl → gnu，任意一个「下载成功 且 能实际运行」就算过
  local try_order=("musl" "gnu")

  tmp=$(mktemp -d)
  local installed=0 last_err=""
  for lc in "${try_order[@]}"; do
    asset="nowhere-${arch_name}-unknown-linux-${lc}.tar.gz"
    url="https://github.com/NodePassProject/Nowhere/releases/download/${tag}/${asset}"
    info "尝试: $asset"

    if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp/nowhere.pkg" "$url"; then
      last_err="下载失败: $url"
      warn "$last_err"
      continue
    fi

    rm -rf "$tmp/extract"; mkdir -p "$tmp/extract"
    tar -xzf "$tmp/nowhere.pkg" -C "$tmp/extract" || true
    bin=$(find "$tmp/extract" -type f -name "nowhere" | head -1)
    if [[ -z "$bin" ]]; then
      last_err="解压后未找到 nowhere 二进制 ($asset)"
      warn "$last_err"
      continue
    fi

    install -m 755 "$bin" "$NOWHERE_BIN"

    # 关键：实际运行一次验证，而不是吞掉报错假装成功（GLIBC 版本不兼容等问题必须暴露出来）
    local verify_out
    if verify_out=$("$NOWHERE_BIN" --version 2>&1); then
      info "Nowhere 已安装并验证可运行 → $NOWHERE_BIN ($verify_out)"
      installed=1
      break
    else
      last_err="二进制无法运行 ($asset): $verify_out"
      warn "$last_err"
      warn "可能是 libc 版本不兼容，尝试另一种构建..."
      continue
    fi
  done

  rm -rf "$tmp"

  if [[ "$installed" -ne 1 ]]; then
    error "Nowhere 安装失败：$last_err"
    error "可手动排查：
  curl -fL -o /tmp/nw.tgz $url
  tar -xzf /tmp/nw.tgz -C /tmp
  /tmp/nowhere --version   # 直接看真实报错，例如 GLIBC 版本不兼容"
    return 1
  fi
}

build_agent() {
  info "编译 Nowhere Agent（静态）..."
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"

  cat > main.go << 'GOPROGRAM'
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Config struct {
	PanelURL     string
	NodeToken    string
	NodeID       string
	NodeName     string
	PortStart    int
	PortEnd      int
	PollInterval int
	TLSMode      int
	CrtPath      string
	KeyPath      string
	NowhereBin   string
	DefaultUp    string
	DefaultDown  string
	MorphEnabled bool
	Socks5Enabled bool
	Socks5Host string
	Socks5Port int
	Socks5Username string
	Socks5Password string
}

func loadConfig() *Config {
	c := &Config{
		PanelURL:     strings.TrimRight(os.Getenv("PANEL_URL"), "/"),
		NodeToken:    os.Getenv("NODE_TOKEN"),
		NodeID:       os.Getenv("NODE_ID"),
		NodeName:     envOr("NODE_NAME", "Nowhere"),
		PortStart:    envInt("PORT_START", 20000),
		PortEnd:      envInt("PORT_END", 30000),
		PollInterval: envInt("POLL_INTERVAL", 20),
		TLSMode:      envInt("TLS_MODE", 1),
		CrtPath:      os.Getenv("CRT_PATH"),
		KeyPath:      os.Getenv("KEY_PATH"),
		NowhereBin:   envOr("NOWHERE_BIN", "/usr/local/bin/nowhere"),
		DefaultUp:    envOr("DEFAULT_UP", "tcp"),
		DefaultDown:  envOr("DEFAULT_DOWN", "tcp"),
	}
	if c.PanelURL == "" || c.NodeToken == "" || c.NodeID == "" {
		log.Fatal("必须设置 PANEL_URL / NODE_TOKEN / NODE_ID")
	}
	return c
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return def
}

type PanelUser struct {
	UserID    int64  `json:"user_id"`
	Port      int    `json:"port"`
	SharedKey string `json:"shared_key"`
	RateUp    int    `json:"rate_up"`
	RateDown  int    `json:"rate_down"`
	Email     string `json:"email"`
}

type UsersResponse struct {
	Data []PanelUser `json:"data"`
	Node struct {
		ID          int    `json:"id"`
		Name        string `json:"name"`
		TLSMode     int    `json:"tls_mode"`
		CrtPath     string `json:"crt_path"`
		KeyPath     string `json:"key_path"`
		DefaultUp   string `json:"default_up"`
		DefaultDown string `json:"default_down"`
		MorphEnabled bool `json:"morph_enabled"`
		Socks5Enabled bool `json:"socks5_enabled"`
		Socks5Host string `json:"socks5_host"`
		Socks5Port int `json:"socks5_port"`
		Socks5Username string `json:"socks5_username"`
		Socks5Password string `json:"socks5_password"`
	} `json:"node"`
}

type RunningPortal struct {
	UserID    int64
	Port      int
	SharedKey string
	RateUp    int
	RateDown  int
    PortalURL string
	Cmd       *exec.Cmd
	StartedAt time.Time
	LastUpload uint64
	LastDownload uint64
}

type CounterSnapshot struct { Upload uint64 `json:"upload"`; Download uint64 `json:"download"` }
type TrafficItem struct { UserID int64 `json:"user_id"`; Upload uint64 `json:"u"`; Download uint64 `json:"d"` }
type TrafficBatch struct { ID string `json:"batch_id"`; Traffic []TrafficItem `json:"traffic"` }
type AgentState struct { Last map[string]CounterSnapshot `json:"last"`; Pending []TrafficBatch `json:"pending"` }
const stateFile = "/var/lib/nowhere-agent/state.json"

type Agent struct {
	cfg     *Config
	mu      sync.Mutex
	running map[int]*RunningPortal
	client  *http.Client
	stopCh  chan struct{}
	iptOK   bool
}

func NewAgent(cfg *Config) *Agent {
	a := &Agent{
		cfg:     cfg,
		running: make(map[int]*RunningPortal),
		client:  &http.Client{Timeout: 15 * time.Second},
		stopCh:  make(chan struct{}),
	}
	a.iptOK = a.ensureIptables()
	return a
}

func runCounterCmd(binary string, args ...string) error {
    return exec.Command(binary, args...).Run()
}
func (a *Agent) ensureIptables() bool {
    if _, err := exec.LookPath("iptables"); err != nil { log.Println("[流量] 未找到 iptables"); return false }
    // Each direction has its own counter chain. INPUT dport = client upload; OUTPUT sport = client download.
    for _, family := range []string{"iptables", "ip6tables"} {
        if _, err := exec.LookPath(family); err != nil { log.Printf("[流量] %s 不可用，将跳过该地址族", family); continue }
        if exec.Command(family, "-S").Run() != nil { continue }
        _ = runCounterCmd(family, "-N", "NOWHERE_IN")
        _ = runCounterCmd(family, "-N", "NOWHERE_OUT")
        if exec.Command(family, "-C", "INPUT", "-j", "NOWHERE_IN").Run() != nil { _ = runCounterCmd(family, "-I", "INPUT", "1", "-j", "NOWHERE_IN") }
        if exec.Command(family, "-C", "OUTPUT", "-j", "NOWHERE_OUT").Run() != nil { _ = runCounterCmd(family, "-I", "OUTPUT", "1", "-j", "NOWHERE_OUT") }
    }
    log.Println("[流量] IPv4/IPv6 双向计数链已初始化")
    return true
}
func (a *Agent) addPortRules(port int) {
    if !a.iptOK { return }
    p := strconv.Itoa(port)
    for _, family := range []string{"iptables", "ip6tables"} {
        if _, err := exec.LookPath(family); err != nil || exec.Command(family, "-S").Run() != nil { continue }
        inChain, outChain := fmt.Sprintf("NWI_%d", port), fmt.Sprintf("NWO_%d", port)
        _ = runCounterCmd(family, "-N", inChain); _ = runCounterCmd(family, "-N", outChain)
        // RETURN target carries counters for packets that match this per-user chain.
        if exec.Command(family, "-C", inChain, "-j", "RETURN").Run() != nil { _ = runCounterCmd(family, "-A", inChain, "-j", "RETURN") }
        if exec.Command(family, "-C", outChain, "-j", "RETURN").Run() != nil { _ = runCounterCmd(family, "-A", outChain, "-j", "RETURN") }
        for _, proto := range []string{"tcp", "udp"} {
            argsIn := []string{"-p", proto, "--dport", p, "-j", inChain}
            if exec.Command(family, append([]string{"-C", "NOWHERE_IN"}, argsIn...)...).Run() != nil { _ = runCounterCmd(family, append([]string{"-A", "NOWHERE_IN"}, argsIn...)...) }
            argsOut := []string{"-p", proto, "--sport", p, "-j", outChain}
            if exec.Command(family, append([]string{"-C", "NOWHERE_OUT"}, argsOut...)...).Run() != nil { _ = runCounterCmd(family, append([]string{"-A", "NOWHERE_OUT"}, argsOut...)...) }
        }
    }
}
func (a *Agent) delPortRules(port int) {
    if !a.iptOK { return }; p := strconv.Itoa(port)
    for _, family := range []string{"iptables", "ip6tables"} {
        if _, err := exec.LookPath(family); err != nil { continue }
        inChain, outChain := fmt.Sprintf("NWI_%d", port), fmt.Sprintf("NWO_%d", port)
        for _, proto := range []string{"tcp", "udp"} {
            _ = runCounterCmd(family, "-D", "NOWHERE_IN", "-p", proto, "--dport", p, "-j", inChain)
            _ = runCounterCmd(family, "-D", "NOWHERE_OUT", "-p", proto, "--sport", p, "-j", outChain)
        }
        _ = runCounterCmd(family, "-F", inChain); _ = runCounterCmd(family, "-X", inChain)
        _ = runCounterCmd(family, "-F", outChain); _ = runCounterCmd(family, "-X", outChain)
    }
}
func readChainBytes(family, chain string) uint64 {
    out, err := exec.Command(family, "-L", chain, "-v", "-n", "-x").Output(); if err != nil { return 0 }
    var total uint64
    for _, line := range strings.Split(string(out), "\n") { f := strings.Fields(line); if len(f) >= 3 && f[0] != "pkts" && f[0] != "Chain" { if b, e := strconv.ParseUint(f[1], 10, 64); e == nil { total += b } } }
    return total
}
func (a *Agent) readPortCounters(port int) CounterSnapshot {
    p := strconv.Itoa(port); var c CounterSnapshot
    for _, family := range []string{"iptables", "ip6tables"} {
        if _, err := exec.LookPath(family); err != nil { continue }
        c.Upload += readChainBytes(family, fmt.Sprintf("NWI_%s", p))
        c.Download += readChainBytes(family, fmt.Sprintf("NWO_%s", p))
    }
    return c
}
func loadAgentState() AgentState {
    s := AgentState{Last: map[string]CounterSnapshot{}, Pending: []TrafficBatch{}}
    b, err := os.ReadFile(stateFile); if err == nil { _ = json.Unmarshal(b, &s) }
    if s.Last == nil { s.Last = map[string]CounterSnapshot{} }; if s.Pending == nil { s.Pending = []TrafficBatch{} }; return s
}
func saveAgentState(s AgentState) error {
    if err := os.MkdirAll(filepath.Dir(stateFile), 0700); err != nil { return err }
    b, err := json.Marshal(s); if err != nil { return err }
    tmp := stateFile + ".tmp"; if err = os.WriteFile(tmp, b, 0600); err != nil { return err }; return os.Rename(tmp, stateFile)
}
func newBatchID() string { b := make([]byte, 16); if _, err := rand.Read(b); err != nil { return fmt.Sprintf("%032x", time.Now().UnixNano()) }; return hex.EncodeToString(b) }
func (a *Agent) collectAndReportTraffic() {
    a.mu.Lock()
    state := loadAgentState()
    batch := TrafficBatch{ID: newBatchID()}
    for port, rp := range a.running {
        cur := a.readPortCounters(port); key := strconv.Itoa(port); prev, ok := state.Last[key]
        if !ok { // First observation establishes baseline; do not charge pre-existing counter history.
            state.Last[key] = cur; continue
        }
        up, down := uint64(0), uint64(0)
        if cur.Upload >= prev.Upload { up = cur.Upload - prev.Upload } else { up = cur.Upload } // counter reset: count new epoch only
        if cur.Download >= prev.Download { down = cur.Download - prev.Download } else { down = cur.Download }
        state.Last[key] = cur
        if up > 0 || down > 0 { batch.Traffic = append(batch.Traffic, TrafficItem{UserID: rp.UserID, Upload: up, Download: down}) }
    }
    if len(batch.Traffic) > 0 { state.Pending = append(state.Pending, batch) }
    if err := saveAgentState(state); err != nil { log.Printf("[流量] 状态持久化失败，暂停本轮上报: %v", err); a.mu.Unlock(); return }
    pending := append([]TrafficBatch(nil), state.Pending...)
    a.mu.Unlock()
    for _, b := range pending {
        if a.reportTraffic(b) {
            a.mu.Lock(); latest := loadAgentState(); filtered := latest.Pending[:0]
            for _, item := range latest.Pending { if item.ID != b.ID { filtered = append(filtered, item) } }
            latest.Pending = filtered
            if err := saveAgentState(latest); err != nil { log.Printf("[流量] 已确认批次但清理队列失败，将依靠幂等键重试: %v", err) }
            a.mu.Unlock()
        }
    }
}

func (a *Agent) fetchUsers() ([]PanelUser, error) {
	url := fmt.Sprintf("%s/api/v1/nowhere/node/%s/users", a.cfg.PanelURL, a.cfg.NodeID)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.cfg.NodeToken)
	req.Header.Set("Accept", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("请求面板失败: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("面板返回 %d: %s", resp.StatusCode, string(body))
	}
	var result UsersResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}
	if result.Node.TLSMode > 0 {
		a.cfg.TLSMode = result.Node.TLSMode
	}
	if result.Node.CrtPath != "" {
		a.cfg.CrtPath = result.Node.CrtPath
	}
	if result.Node.KeyPath != "" {
		a.cfg.KeyPath = result.Node.KeyPath
	}
	if result.Node.DefaultUp != "" {
		a.cfg.DefaultUp = result.Node.DefaultUp
	}
	if result.Node.DefaultDown != "" {
		a.cfg.DefaultDown = result.Node.DefaultDown
	}
	a.cfg.MorphEnabled = result.Node.MorphEnabled
	a.cfg.Socks5Enabled = result.Node.Socks5Enabled
	a.cfg.Socks5Host = result.Node.Socks5Host
	a.cfg.Socks5Port = result.Node.Socks5Port
	a.cfg.Socks5Username = result.Node.Socks5Username
	a.cfg.Socks5Password = result.Node.Socks5Password
	return result.Data, nil
}

func (a *Agent) reportTraffic(batch TrafficBatch) bool {
    url := fmt.Sprintf("%s/api/v1/nowhere/node/%s/report", a.cfg.PanelURL, a.cfg.NodeID)
    type payloadItem struct { UserID int64 `json:"user_id"`; U uint64 `json:"u"`; D uint64 `json:"d"` }
    items := make([]payloadItem, 0, len(batch.Traffic))
    for _, t := range batch.Traffic { items = append(items, payloadItem{UserID:t.UserID, U:t.Upload, D:t.Download}) }
    body, _ := json.Marshal(map[string]interface{}{"batch_id": batch.ID, "traffic": items})
    req, err := http.NewRequest("POST", url, bytes.NewReader(body)); if err != nil { log.Printf("[上报] 创建请求失败: %v", err); return false }
    req.Header.Set("Authorization", "Bearer "+a.cfg.NodeToken); req.Header.Set("Content-Type", "application/json")
    resp, err := a.client.Do(req); if err != nil { log.Printf("[上报] 失败，保留待重试批次 %s: %v", batch.ID, err); return false }
    defer resp.Body.Close(); _, _ = io.Copy(io.Discard, resp.Body)
    if resp.StatusCode < 200 || resp.StatusCode >= 300 { log.Printf("[上报] HTTP %d，保留批次 %s", resp.StatusCode, batch.ID); return false }
    log.Printf("[流量] 批次 %s 已被面板确认", batch.ID); return true
}

func (a *Agent) buildPortalURL(u PanelUser) string {
    params := []string{"morph=1"}
    if !a.cfg.MorphEnabled { params = []string{"morph=0"} }
    if a.cfg.Socks5Enabled && a.cfg.Socks5Host != "" && a.cfg.Socks5Port > 0 {
        auth := ""
        if a.cfg.Socks5Username != "" { auth = url.QueryEscape(a.cfg.Socks5Username) + ":" + url.QueryEscape(a.cfg.Socks5Password) + "@" }
        params = append(params, "out="+auth+a.cfg.Socks5Host+":"+strconv.Itoa(a.cfg.Socks5Port))
    } else { params = append(params, "out=direct") }
    if u.RateUp > 0 { params = append(params, fmt.Sprintf("rate=%d", u.RateUp)) }
    if u.RateDown > 0 { params = append(params, fmt.Sprintf("etar=%d", u.RateDown)) }
    if a.cfg.TLSMode == 2 && a.cfg.CrtPath != "" && a.cfg.KeyPath != "" {
        params = append(params, "tls=2", "crt="+url.QueryEscape(a.cfg.CrtPath), "key="+url.QueryEscape(a.cfg.KeyPath))
    } else { params = append(params, "tls=1") }
    return fmt.Sprintf("portal://%s@*:%d?%s", u.SharedKey, u.Port, strings.Join(params, "&"))
}

const portalLogDir = "/var/log/nowhere-agent"

// 杀掉可能残留占用该端口的旧进程（重装/手动测试/异常退出遗留的僵尸进程会导致新进程 bind 失败，
// 之前发生过这种情况：新用户端口一直连不上，实际是端口被一个用旧 key 启动的僵尸进程占用了）
func (a *Agent) killPortSquatter(port int) {
	for _, proto := range []string{"tcp", "udp"} {
		_ = exec.Command("fuser", "-k", "-n", proto, strconv.Itoa(port)).Run()
	}
}

func tailFile(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " | ")
}

func (a *Agent) startPortal(u PanelUser) error {
	a.mu.Lock()
	defer a.mu.Unlock()

    portalURL := a.buildPortalURL(u)
	if old, ok := a.running[u.Port]; ok {
		if old.SharedKey == u.SharedKey && old.RateUp == u.RateUp && old.RateDown == u.RateDown && old.PortalURL == portalURL {
			return nil
		}
		a.stopPortalLocked(u.Port)
	}

	// 启动前先清理端口上可能残留的旧进程，避免 bind 失败
	a.killPortSquatter(u.Port)
	log.Printf("[启动] 用户%d 端口%d rate=%d/%d morph=%v", u.UserID, u.Port, u.RateUp, u.RateDown, a.cfg.MorphEnabled)

	_ = os.MkdirAll(portalLogDir, 0755)
	logPath := filepath.Join(portalLogDir, fmt.Sprintf("port-%d.log", u.Port))
	logFile, ferr := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)

	cmd := exec.Command(a.cfg.NowhereBin, portalURL)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if ferr == nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	} else {
		log.Printf("[警告] 端口%d 日志文件打开失败: %v（将看不到 nowhere 自身报错）", u.Port, ferr)
	}
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			logFile.Close()
		}
		return err
	}

	startedAt := time.Now()
	a.addPortRules(u.Port)
    // A newly created per-port counter starts at zero. Persist that baseline before any traffic is collected.
    // If this port existed previously, its rules were removed above and the counter epoch has restarted.
    state := loadAgentState()
    if state.Last == nil { state.Last = map[string]CounterSnapshot{} }
    state.Last[strconv.Itoa(u.Port)] = CounterSnapshot{}
    if err := saveAgentState(state); err != nil { log.Printf("[流量] 初始化端口%d计数基线失败: %v", u.Port, err) }
	a.running[u.Port] = &RunningPortal{
		UserID: u.UserID, Port: u.Port, SharedKey: u.SharedKey,
		RateUp: u.RateUp, RateDown: u.RateDown, PortalURL: portalURL, Cmd: cmd, StartedAt: startedAt,
		LastUpload: a.readPortCounters(u.Port).Upload,
		LastDownload: a.readPortCounters(u.Port).Download,
	}

	go func(c *exec.Cmd, port int, lf *os.File, started time.Time) {
		_ = c.Wait()
		if lf != nil {
			lf.Close()
		}
		alive := time.Since(started)
		a.mu.Lock()
		if rp, ok := a.running[port]; ok && rp.Cmd == c {
			delete(a.running, port)
			a.delPortRules(port)
		}
		a.mu.Unlock()
		// 存活时间过短基本可以断定是启动失败/崩溃（而不是被正常 stop），把日志尾部直接打到 journalctl，
		// 不用再手动前台跑二进制去猜错误
		if alive < 3*time.Second {
			tail := tailFile(filepath.Join(portalLogDir, fmt.Sprintf("port-%d.log", port)), 5)
			log.Printf("[崩溃] 端口%d 的 nowhere 进程存活仅 %.1fs 就退出，疑似启动失败。最近日志: %s",
				port, alive.Seconds(), tail)
		}
	}(cmd, u.Port, logFile, startedAt)
	return nil
}

func (a *Agent) stopPortalLocked(port int) {
	if rp, ok := a.running[port]; ok {
		log.Printf("[停止] 端口 %d 用户%d", port, rp.UserID)
		if rp.Cmd != nil && rp.Cmd.Process != nil {
			_ = syscall.Kill(-rp.Cmd.Process.Pid, syscall.SIGTERM)
			time.Sleep(200 * time.Millisecond)
			_ = syscall.Kill(-rp.Cmd.Process.Pid, syscall.SIGKILL)
		}
		a.delPortRules(port)
		delete(a.running, port)
	}
}

func (a *Agent) stopPortal(port int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.stopPortalLocked(port)
}

func (a *Agent) stopAll() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for port := range a.running {
		a.stopPortalLocked(port)
	}
}

// Nowhere v3.0.0 requires exactly 32 lowercase hexadecimal characters (16 bytes).
func validSharedKey(s string) bool {
    if len(s) != 32 || s != strings.ToLower(s) { return false }
    b, err := hex.DecodeString(s)
    return err == nil && len(b) == 16
}

func (a *Agent) syncOnce() {
	// 先上报流量增量
	a.collectAndReportTraffic()

	users, err := a.fetchUsers()
	if err != nil {
		log.Printf("[轮询] 失败: %v", err)
		return
	}
	log.Printf("[轮询] %d 个有效用户", len(users))

	want := map[int]PanelUser{}
	for _, u := range users {
        if u.Port <= 0 { continue }
        if !validSharedKey(u.SharedKey) {
            // Do not echo the key into logs. The panel plugin should rotate legacy keys before returning them.
            log.Printf("[错误] 端口 %d 收到格式不兼容的 shared_key（要求 32 位小写 hex）；请更新面板插件/检查 API 下发", u.Port)
            continue
        }
        want[u.Port] = u
    }

	a.mu.Lock()
	var toStop []int
	for port := range a.running {
		if _, ok := want[port]; !ok {
			toStop = append(toStop, port)
		}
	}
	a.mu.Unlock()
	for _, p := range toStop {
		a.stopPortal(p)
	}
	for _, u := range want {
		if err := a.startPortal(u); err != nil {
			log.Printf("[错误] 端口 %d: %v", u.Port, err)
		}
	}
	a.mu.Lock()
	n := len(a.running)
	a.mu.Unlock()
	log.Printf("[状态] 运行中 Portal: %d", n)
}

func (a *Agent) Run() {
	log.Printf("Nowhere Agent 启动 | Panel=%s NodeID=%s Poll=%ds iptables=%v",
		a.cfg.PanelURL, a.cfg.NodeID, a.cfg.PollInterval, a.iptOK)
	if _, err := os.Stat(a.cfg.NowhereBin); err != nil {
		log.Fatalf("找不到 nowhere: %s", a.cfg.NowhereBin)
	}
	ticker := time.NewTicker(time.Duration(a.cfg.PollInterval) * time.Second)
	defer ticker.Stop()
	a.syncOnce()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	for {
		select {
		case <-ticker.C:
			a.syncOnce()
		case <-sigCh:
			log.Println("退出中...")
			a.collectAndReportTraffic()
			a.stopAll()
			return
		}
	}
}

func main() {
	log.SetFlags(log.LstdFlags)
	loadEnvFile("/etc/nowhere-agent/config.env")
	NewAgent(loadConfig()).Run()
}

func loadEnvFile(path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 && os.Getenv(strings.TrimSpace(parts[0])) == "" {
			_ = os.Setenv(strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]))
		}
	}
	_ = os.Chdir(filepath.Dir(path))
}

GOPROGRAM

  export CGO_ENABLED=0
  export GOOS=linux
  export GOARCH=$GOARCH
  export PATH=/usr/local/go/bin:$PATH

  go mod init nowhere-agent >/dev/null 2>&1 || true
  go build -ldflags="-s -w" -o nowhere-agent main.go

  install -m 755 nowhere-agent "$AGENT_BIN"
  info "Agent 编译完成 → $AGENT_BIN"
  cd /
  rm -rf "$WORK_DIR"
}

write_config() {
  case "${NOW_MORPH_TCP_PRELUDE:-full8}" in
    low7|full8) ;;
    *) warn "无效 Prelude 值，改用 full8（8-bit random）"; NOW_MORPH_TCP_PRELUDE="full8" ;;
  esac
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" << EOF
PANEL_URL=$PANEL_URL
NODE_TOKEN=$NODE_TOKEN
NODE_ID=$NODE_ID
NODE_NAME=$NODE_NAME
PORT_START=$PORT_START
PORT_END=$PORT_END
POLL_INTERVAL=$POLL_INTERVAL
NOW_MORPH_TCP_PRELUDE=${NOW_MORPH_TCP_PRELUDE:-full8}
TLS_MODE=1
# 如需自定义证书（tls=2），取消下面注释并填写路径
# CRT_PATH=/path/to/fullchain.pem
# KEY_PATH=/path/to/privkey.pem
EOF
  chmod 600 "$CONFIG_FILE"
  info "配置已写入 $CONFIG_FILE"
}

install_service() {
  cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Nowhere Agent for Xboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_FILE
ExecStart=$AGENT_BIN
Restart=always
RestartSec=5
LimitNOFILE=1048576
WorkingDirectory=$CONFIG_DIR

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  if ! systemctl enable ${SERVICE_NAME} 2>/dev/null; then
    error "systemctl enable 失败"
    return 1
  fi
  # 关键：不能用 enable --now，它对已经在运行的服务是空操作——旧进程还在跑旧二进制，
  # 磁盘上的文件换了新版本也不会生效。必须用 restart 强制换成新进程。
  if ! systemctl restart ${SERVICE_NAME}; then
    error "systemctl restart 失败"
    return 1
  fi
  sleep 1
  if ! systemctl is-active --quiet ${SERVICE_NAME}; then
    error "服务已注册但未能进入运行状态"
    journalctl -u ${SERVICE_NAME} -n 30 --no-pager || true
    return 1
  fi
  info "systemd 服务已重启并设置开机自启"
}

do_install() {
  clear
  title "====== 安装 / 重新安装 Nowhere Agent 节点 ======"
  echo

  read -rp "面板地址 (例: https://panel.example.com): " PANEL_URL
  [[ -z "$PANEL_URL" ]] && { error "面板地址不能为空"; pause; return; }

  read -rp "节点 Token: " NODE_TOKEN
  [[ -z "$NODE_TOKEN" ]] && { error "Token 不能为空"; pause; return; }

  read -rp "节点 ID (数字): " NODE_ID
  [[ -z "$NODE_ID" ]] && { error "节点 ID 不能为空"; pause; return; }

  read -rp "节点显示名称 [Nowhere]: " input_name
  NODE_NAME=${input_name:-Nowhere}

  read -rp "端口池起始 [20000]: " input_start
  PORT_START=${input_start:-20000}

  read -rp "端口池结束 [30000]: " input_end
  PORT_END=${input_end:-30000}

  read -rp "轮询间隔秒 [20]: " input_poll
  POLL_INTERVAL=${input_poll:-20}

  echo
  info "即将开始安装，请确认："
  echo "  面板地址 : $PANEL_URL"
  echo "  节点 ID  : $NODE_ID"
  echo "  节点名称 : $NODE_NAME"
  echo "  端口池   : $PORT_START - $PORT_END"
  echo "  轮询间隔 : ${POLL_INTERVAL}s"
  echo "  Morph Prelude : ${NOW_MORPH_TCP_PRELUDE:-full8}（客户端策略；Portal 服务端无需配置）"
  echo
  read -rp "确认安装？(y/N): " confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "已取消安装"; pause; return; }

  # 重装前先停掉旧服务，避免安装过程中新旧 agent / 旧的手动测试进程同时占用端口
  if service_exists; then
    info "检测到已有服务，先停止旧服务..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  fi
  # 清理可能残留的旧 nowhere 子进程（比如之前手动前台测试过、或异常退出没清理干净的），
  # 但不动 nowhere-agent 本身，避免这类僵尸进程占用端口导致新用户连不上
  pkill -f "^${NOWHERE_BIN} portal://" 2>/dev/null || true

  detect_arch

  if ! install_deps; then
    error "系统依赖安装失败，请检查上方输出（常见于源不可用/网络问题）"
    pause; return
  fi

  # install_deps 是批量安装，某一个包装失败很容易被忽略过去；这里逐个核实
  # 真正跑起来必需的命令，缺了就再单独尝试装一次，装完还是没有才真正报错终止。
  if ! ensure_cmd "curl"; then
    error "curl 不可用，无法继续安装（下载 Go / Nowhere / 查询 GitHub 版本均依赖它）"
    pause; return
  fi
  if ! ensure_cmd "tar"; then
    error "tar 不可用，无法继续安装（解压 Go / Nowhere 均依赖它）"
    pause; return
  fi
  if ! ensure_cmd "fuser" "psmisc"; then
    warn "fuser 不可用，端口占用清理功能会失效，但不影响主流程，继续安装"
  fi

  # iptables 是流量统计的核心依赖，必须单独做功能性验证（见 ensure_iptables 注释）
  ensure_iptables

  if ! install_go; then
    error "Go 环境安装失败，请检查网络是否能访问 https://go.dev"
    pause; return
  fi
  if ! install_nowhere; then
    error "Nowhere 二进制安装失败，请检查上方报错后重试（GLIBC 不兼容 / 网络访问 GitHub 失败等）"
    pause; return
  fi
  if ! build_agent; then
    error "Agent 编译失败，请检查上方 go build 报错"
    pause; return
  fi
  if ! write_config; then
    error "写入配置文件失败"
    pause; return
  fi
  if ! install_service; then
    error "systemd 服务安装/启动失败，请查看: journalctl -u ${SERVICE_NAME} -n 50"
    pause; return
  fi

  # 真正校验服务是否起来了，而不是无脑打印"安装完成"
  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo
    info "=========================================="
    info "安装完成，服务运行正常！"
    info "查看状态: systemctl status ${SERVICE_NAME}"
    info "查看日志: journalctl -u ${SERVICE_NAME} -f"
    info "配置文件: $CONFIG_FILE"
    if [[ "$IPTABLES_WORKING" -eq 1 ]]; then
      info "流量统计  : IPv4/IPv6 分方向计数已配置，正常统计上报"
    else
      warn "流量统计  : iptables 不可用，流量上报会恒为 0（详情见上方安装日志）"
    fi
    info "=========================================="
  else
    echo
    error "=========================================="
    error "安装流程已跑完，但服务当前不是运行状态！"
    error "请查看具体报错: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
    error "=========================================="
  fi
  pause
}

# ====================== 其他功能 ======================
show_status() {
  clear
  title "====== 服务状态 ======"
  echo
  if service_exists; then
    systemctl status "${SERVICE_NAME}" --no-pager || true
  else
    warn "服务尚未安装"
  fi
  pause
}

show_logs() {
  clear
  title "====== 实时日志 (Ctrl+C 退出) ======"
  echo
  if service_exists; then
    journalctl -u "${SERVICE_NAME}" -f --no-pager
  else
    warn "服务尚未安装"
    pause
  fi
}

show_users() {
  clear
  title "====== 拉取用户列表 ======"
  echo
  if ! load_config; then
    warn "尚未安装或配置文件不存在"
    pause
    return
  fi

  info "完整 Agent 已编译。查看实时日志可看到轮询与启停信息。"
  info "也可直接请求面板 /api/v1/nowhere/node/{id}/users 查看。"
  echo
  echo "配置信息："
  echo "  PANEL_URL     = $PANEL_URL"
  echo "  NODE_ID       = $NODE_ID"
  echo "  PORT_START    = $PORT_START"
  echo "  PORT_END      = $PORT_END"
  echo "  POLL_INTERVAL = $POLL_INTERVAL"
  echo
  warn ""
  pause
}

start_service() {
  if service_exists; then
    systemctl start "${SERVICE_NAME}"
    info "服务已启动"
  else
    warn "服务尚未安装"
  fi
  pause
}

stop_service() {
  if service_exists; then
    systemctl stop "${SERVICE_NAME}"
    info "服务已停止"
  else
    warn "服务尚未安装"
  fi
  pause
}

restart_service() {
  if service_exists; then
    systemctl restart "${SERVICE_NAME}"
    info "服务已重启"
  else
    warn "服务尚未安装"
  fi
  pause
}

show_config() {
  clear
  title "====== 当前配置文件 ======"
  echo
  if [[ -f "$CONFIG_FILE" ]]; then
    cat "$CONFIG_FILE"
  else
    warn "配置文件不存在，请先安装"
  fi
  pause
}

do_uninstall() {
  clear
  title "====== 卸载节点 ======"
  echo
  read -rp "确认卸载？这将停止服务并删除相关文件 (y/N): " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    warn "已取消"
    pause
    return
  fi

  info "停止服务并清理整个 systemd 进程组..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  if service_exists; then
    systemctl kill --kill-who=all --signal=SIGKILL "${SERVICE_NAME}" 2>/dev/null || true
  fi
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  rm -f "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
  systemctl daemon-reload

  # 兜底：清理所有 Agent 创建的 nowhere portal 子进程
  info "清理残留 nowhere 子进程..."
  pkill -f "^${NOWHERE_BIN} portal://" 2>/dev/null || true
  sleep 1
  pkill -9 -f "^${NOWHERE_BIN} portal://" 2>/dev/null || true

  # 清理 v14 IPv4/IPv6 统计规则；保留 /var/lib/nowhere-agent/state.json，便于人工恢复待上报批次。
  for family in iptables ip6tables; do
    command -v "$family" >/dev/null 2>&1 || continue
    while "$family" -C INPUT -j NOWHERE_IN 2>/dev/null; do "$family" -D INPUT -j NOWHERE_IN 2>/dev/null || break; done
    while "$family" -C OUTPUT -j NOWHERE_OUT 2>/dev/null; do "$family" -D OUTPUT -j NOWHERE_OUT 2>/dev/null || break; done
    for chain in $("$family" -S 2>/dev/null | grep -oE '^-N NWI_[0-9]+|^-N NWO_[0-9]+' | awk '{print $2}'); do
      "$family" -F "$chain" 2>/dev/null || true
      "$family" -X "$chain" 2>/dev/null || true
    done
    "$family" -F NOWHERE_IN 2>/dev/null || true
    "$family" -X NOWHERE_IN 2>/dev/null || true
    "$family" -F NOWHERE_OUT 2>/dev/null || true
    "$family" -X NOWHERE_OUT 2>/dev/null || true
  done

  rm -f "$AGENT_BIN"
  rm -rf "$CONFIG_DIR"
  rm -rf /var/log/nowhere-agent

  echo
  read -rp "是否同时删除 Nowhere 二进制本体 ($NOWHERE_BIN)？(y/N): " del_bin
  if [[ "$del_bin" == "y" || "$del_bin" == "Y" ]]; then
    rm -f "$NOWHERE_BIN"
    info "已删除 $NOWHERE_BIN"
  else
    info "保留 $NOWHERE_BIN"
  fi

  # 最终真实校验，而不是无脑打印"卸载完成"
  sleep 1
  local leftover=0
  if pgrep -f "^${NOWHERE_BIN} portal://" >/dev/null 2>&1; then
    warn "仍检测到残留的 nowhere portal 子进程，请手动检查: ps aux | grep nowhere"
    leftover=1
  fi
  if service_exists; then
    warn "systemd 单元似乎仍存在，请手动检查: systemctl cat ${SERVICE_NAME}.service"
    leftover=1
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    warn "配置文件仍存在: $CONFIG_FILE"
    leftover=1
  fi
  if [[ "$leftover" -eq 0 ]]; then
    info "卸载完成，未检测到残留进程/服务"
  fi
  pause
}

# ====================== 主循环 ======================
main() {
  check_root

  while true; do
    show_menu
    read -rp "请选择操作 [0-9]: " choice
    case "$choice" in
      1) do_install ;;
      2) show_status ;;
      3) show_logs ;;
      4) show_users ;;
      5) start_service ;;
      6) stop_service ;;
      7) restart_service ;;
      8) show_config ;;
      9) do_uninstall ;;
      0) echo; info "退出脚本"; exit 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

main "$@"
