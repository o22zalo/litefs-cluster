# LiteFS Cluster trên Tailscale — GitHub Actions

## Kiến trúc

```
GitHub Actions Runner A          GitHub Actions Runner B          GitHub Actions Runner C
┌─────────────────────────┐      ┌─────────────────────────┐      ┌─────────────────────────┐
│  Docker Container        │      │  Docker Container        │      │  Docker Container        │
│  ┌─────────────────────┐ │      │  ┌─────────────────────┐ │      │  ┌─────────────────────┐ │
│  │ tailscaled          │ │      │  │ tailscaled          │ │      │  │ tailscaled          │ │
│  │ 100.x.1.x           │ │      │  │ 100.x.2.x           │ │      │  │ 100.x.3.x           │ │
│  ├─────────────────────┤ │      │  ├─────────────────────┤ │      │  ├─────────────────────┤ │
│  │ Consul Server       │◄├──────┼──┤ Consul Server       │◄├──────┼──┤ Consul Server       │ │
│  │ (bootstrap/LEADER)  │ │      │  │ (follower)          │ │      │  │ (follower)          │ │
│  ├─────────────────────┤ │      │  ├─────────────────────┤ │      │  ├─────────────────────┤ │
│  │ LiteFS (PRIMARY)    │◄├──────┼──┤ LiteFS (REPLICA)    │◄├──────┼──┤ LiteFS (REPLICA)    │ │
│  │ SQLite writes here  │ │      │  │ Reads replicated     │ │      │  │ Reads replicated     │ │
│  └─────────────────────┘ │      │  └─────────────────────┘ │      │  └─────────────────────┘ │
└─────────────────────────┘      └─────────────────────────┘      └─────────────────────────┘
         ▲ Node A (cũ nhất)                                                Tailscale VPN
         │ Bootstrap leader tự nhiên vì khởi động đầu tiên
         │
         └── Khi A stop sau 50 phút → consul leave → B hoặc C tự elect leader mới
```

## Yêu cầu trước khi chạy

### 1. Tailscale — Cấu hình ACL

Vào **Tailscale Admin Console → Access Controls**, thêm:

```json
{
  "tagOwners": {
    "tag:litefs-node": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src":    ["tag:litefs-node"],
      "dst":    ["tag:litefs-node:*"]
    }
  ]
}
```

### 2. Tailscale — Tạo Auth Key

1. Vào **Settings → Keys → Generate auth key**
2. Cấu hình:
   - ✅ **Reusable** (quan trọng! Vì nhiều workflow dùng chung key)
   - ✅ **Ephemeral** (node tự xóa khỏi Tailscale khi stop)
   - **Pre-approved tags**: `tag:litefs-node`
   - Expiry: 90 ngày hoặc hơn
3. Copy key (dạng `tskey-auth-...`)

### 3. GitHub — Thêm Secret

Vào **GitHub repo → Settings → Secrets and variables → Actions → New secret**:

| Name | Value |
|------|-------|
| `TS_AUTHKEY` | `tskey-auth-xxxxx` |

## Cách chạy

### Khởi động cluster (3 workflow song song)

```
GitHub → Actions → "LiteFS Node A" → Run workflow
GitHub → Actions → "LiteFS Node B" → Run workflow  (cách A ~10 giây)
GitHub → Actions → "LiteFS Node C" → Run workflow  (cách B ~10 giây)
```

Nên khởi A trước, rồi B, rồi C để dễ quan sát bootstrap sequence.

### Quan sát rolling rotation

1. A khởi động → tự bootstrap làm Consul leader
2. B join → cluster 2 nodes
3. C join → cluster 3 nodes
4. A stop sau ~40 phút → B hoặc C tự elect leader mới
5. Có thể start lại A → join cluster với leader mới

## Proof points trong logs

### Chứng minh node cũ nhất = leader
```
[BOOTSTRAP] Mode: LEADER (bootstrap)     ← Node A (không thấy peer nào)
[BOOTSTRAP] Mode: FOLLOWER → joining ... ← Node B, C (thấy A đã có Consul)
```

### Chứng minh replication
```
--- writers breakdown (proves replication) ---
node_name    node_ip     count  last_write
node-a-123   100.x.1.x  10     2024-01-01 10:30:00  ← ghi trên primary
node-b-123   100.x.2.x  0      ...                   ← không ghi (replica)
```
Node B và C đọc được heartbeats của A → replication hoạt động.

### Chứng minh failover
Khi A stop:
```
[BOOTSTRAP] Leaving Consul cluster...    ← consul leave được gọi
```
Consul cluster tự re-elect B hoặc C làm leader trong <5 giây.
LiteFS tự acquire Consul lock mới → node mới trở thành primary.

## Cấu trúc file

```
.
├── .github/workflows/
│   ├── node-a.yml        ← Workflow node A
│   ├── node-b.yml        ← Workflow node B
│   └── node-c.yml        ← Workflow node C
└── docker/
    ├── Dockerfile
    ├── config/
    │   ├── consul.hcl    ← Consul config
    │   └── litefs.yml    ← LiteFS config
    └── scripts/
        ├── entrypoint.sh ← Start tailscaled → bootstrap → litefs
        ├── bootstrap.sh  ← Discover peers, start Consul leader/follower
        ├── run-app.sh    ← App chạy qua LiteFS exec (heartbeat loop)
        ├── verify.sh     ← Chứng minh cluster hoạt động
        └── backup.sh     ← Snapshot SQLite định kỳ lên S3 (optional)
```


## Biến môi trường quan trọng

| Biến | Mặc định | Mô tả |
|---|---|---|
| `TS_AUTHKEY` | _(bắt buộc)_ | Auth key Tailscale để node tham gia tailnet. |
| `TS_TAGS` | `tag:litefs-node` | Tag dùng để discover peer. |
| `BOOTSTRAP_DISCOVERY_ROUNDS` | `20` | Số vòng discovery seed trước khi chốt. |
| `BOOTSTRAP_STABLE_ROUNDS` | `3` | Số vòng seed phải ổn định để giảm race condition. |
| `BOOTSTRAP_RECOVERY_STEP_SECONDS` | `10` | Bước delay theo rank khi cluster chưa có leader để tránh nhiều node bootstrap đồng thời. |
| `BOOTSTRAP_LEADER_WAIT_SECONDS` | `90` | Thời gian chờ leader xuất hiện sau khi Consul local đã up. |
| `CONSUL_AUTO_RECOVER_NO_LEADER` | `true` | Nếu vẫn không có leader, reset local Consul state và thử lại 1 lần. |
| `BACKUP_ENABLED` | `false` | Bật/tắt backup định kỳ lên S3. |
| `BACKUP_INTERVAL_SECONDS` | `300` | Chu kỳ backup (giây). |
| `BACKUP_S3_BUCKET` | _(rỗng)_ | Bucket S3 để lưu snapshot SQLite. |
| `BACKUP_S3_PREFIX` | `litefs` | Prefix object key trong bucket. |
| `AWS_REGION` | `us-east-1` | Region dùng cho lệnh `aws s3 cp`. |

> Lưu ý: cơ chế bootstrap mới dùng discovery + recovery gate. Nếu đã có leader thì node mới chỉ join follower. Nếu chưa có leader, các node sẽ chờ theo rank IP để chỉ một node bootstrap trước; nhờ đó giảm tình huống toàn cụm kẹt `No cluster leader`.

## Troubleshooting

### Tailscale không kết nối được
- Kiểm tra `TS_AUTHKEY` có đúng tag `tag:litefs-node`
- Kiểm tra ACL có `tagOwners` cho tag đó
- Kiểm tra key là **Reusable** (không phải one-time)

### Consul không join được
- Node cần ~15-30s để Tailscale fully up
- Bootstrap script có startup gate + seed ổn định nhiều vòng để giảm race
- Xem logs: `docker logs litefs-node-a | grep BOOTSTRAP`
- Nếu thấy kẹt `No cluster leader`, script mới sẽ tự thử no-leader recovery (reset local state 1 lần).

### LiteFS không mount
- Cần `--privileged` trong docker run
- Kiểm tra `/etc/fuse.conf` có `user_allow_other`
- Xem: `docker logs litefs-node-a | grep LiteFS`

### Split-brain (2 node đều là leader)
- Xảy ra khi 2 node khởi động đúng cùng lúc và không thấy nhau
- Fix: stop 1 trong 2 node, restart nó
- Phòng ngừa: startup gate + seed ổn định giúp giảm xác suất split-brain ngắn hạn
