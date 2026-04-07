# Đánh giá nhanh codebase LiteFS Cluster

## 1) Tóm tắt ngắn gọn README

- Dự án xây dựng **cụm LiteFS + Consul** chạy trong Docker, kết nối qua **Tailscale** để các node nhìn thấy nhau trên private network.
- Node đầu khởi động thường đóng vai trò bootstrap ban đầu; các node sau join cụm, LiteFS bầu `primary` qua Consul lease key `litefs/primary`.
- Bên trong container có 4 thành phần chính: `tailscaled` (VPN), `consul agent` (quorum/leader election), `litefs mount` (replication + lock), và app demo ghi/đọc SQLite heartbeat.
- Mô hình vận hành theo README thiên về chạy trên **GitHub Actions nhiều workflow song song** để mô phỏng cluster và failover.

## 2) Mức độ đáp ứng hiện tại so với mục tiêu

### Điểm đã đáp ứng tốt

- Có pipeline khởi động tương đối đầy đủ từ network → consul → litefs → app demo qua `entrypoint.sh`.
- Có cơ chế graceful shutdown (`consul leave`) giúp giảm thời gian chờ re-election khi node chết.
- Có script `verify.sh` để kiểm tra nhanh các tín hiệu sống (Tailscale, Consul leader, LiteFS primary, DB replication).
- Cấu hình LiteFS dùng lease Consul chuẩn, có TTL và lock-delay rõ ràng.

### Chưa đáp ứng đầy đủ cho production

- Chưa có workflow orchestrator thống nhất cho môi trường thực (Kubernetes/Nomad/Compose production) và chưa có healthcheck chuẩn cho platform.
- Logic bootstrap Consul hiện hard-code `-bootstrap-expect=2`, không khớp README mô tả 3 node; dễ gây hành vi khó đoán khi scale.
- App demo chạy vô hạn trong `run-app.sh`, chưa có cơ chế supervisor, metric, retry policy, hay graceful degradation.
- Chưa pin/supply-chain hardening (checksum/signature verify) khi tải Consul/LiteFS binary trong Dockerfile.

## 3) Rà soát rủi ro/lỗi có thể xảy ra khi triển khai thực tế

## Nhóm A — Rủi ro điều phối cluster

1. **Sai quorum kỳ vọng (`bootstrap-expect=2`)**
   - Tác động: cụm 3 node nhưng quorum logic thiên về 2 node, có thể khác kỳ vọng vận hành/sự cố.
   - Khuyến nghị: biến thành env `CONSUL_BOOTSTRAP_EXPECT` và mặc định theo số node thật.

2. **Race condition lúc nhiều node lên cùng lúc**
   - Hiện có random backoff, nhưng vẫn có xác suất split-brain ngắn trước khi hội tụ.
   - Khuyến nghị: thêm startup gate (ví dụ kiểm tra lock/leader ổn định N giây) trước khi mở traffic write.

3. **Phụ thuộc mạnh vào Tailscale availability**
   - Nếu auth key hết hạn hoặc ACL sai, toàn bộ node fail từ bước đầu.
   - Khuyến nghị: preflight check + fail-fast message chuẩn hóa + cảnh báo sớm về tuổi thọ key.

## Nhóm B — Rủi ro dữ liệu và ứng dụng

4. **`run-app.sh` thao tác SQL bằng string interpolation**
   - Dữ liệu hiện là nội bộ (IP/hostname), rủi ro injection thấp nhưng vẫn là thói quen không an toàn.
   - Khuyến nghị: sanitize đầu vào hoặc dùng binding/escaping chặt chẽ.

5. **Replica vẫn cố ghi `register_node`**
   - Script đã “nuốt lỗi”, nhưng gây nhiễu log và khó quan sát lỗi thật.
   - Khuyến nghị: chỉ ghi khi chắc chắn primary hoặc tách logging mức debug.

6. **Chưa có backup/restore playbook**
   - LiteFS replication không thay thế backup; corruption logic vẫn có thể replicate.
   - Khuyến nghị: bổ sung snapshot định kỳ và restore test tự động.

## Nhóm C — Rủi ro vận hành và bảo mật

7. **Container cần `--privileged` + FUSE**
   - Tăng bề mặt tấn công, khó qua policy ở môi trường enterprise.
   - Khuyến nghị: đánh giá capability tối thiểu, seccomp/apparmor profile riêng.

8. **Chưa có readiness/liveness endpoint chuẩn**
   - Orchestrator khó biết khi nào node “thật sự sẵn sàng phục vụ”.
   - Khuyến nghị: cung cấp endpoint tổng hợp trạng thái tailscale+consul+litefs.

9. **Thiếu observability chuẩn**
   - Log dạng text đủ debug thủ công nhưng khó vận hành quy mô lớn.
   - Khuyến nghị: thêm metrics (Prometheus), structured logs, alert theo SLO.

## 4) Phương án tích hợp toàn bộ nghiệp vụ thành 1 image (env-driven)

Mục tiêu: **một image duy nhất**, tích hợp với dịch vụ khác chỉ cần truyền ENV, hạn chế sửa code.

## Thiết kế đề xuất

### A. Chuẩn hóa vai trò bằng ENV (không hard-code)

- `CLUSTER_NAME=litefs-cluster`
- `NODE_NAME` (default từ hostname)
- `TS_AUTHKEY` (bắt buộc)
- `TS_TAGS=tag:litefs-node`
- `CONSUL_BOOTSTRAP_EXPECT=3`
- `CONSUL_RETRY_JOIN` (danh sách IP/domain, tùy chọn)
- `LITEFS_CONSUL_KEY=litefs/primary`
- `APP_CMD` (lệnh app thực tế, thay `run-app.sh` demo)
- `APP_DB_PATH=/mnt/litefs/cluster.db`

Ý tưởng: entrypoint render template từ env vào `consul.hcl` và `litefs.yml`, sau đó chạy chuỗi start chuẩn.

### B. Tách “app demo” thành app adapter

- Giữ `run-app.sh` chỉ làm wrapper:
  1) chờ LiteFS mount + primary election ổn định,
  2) chạy `exec "$APP_CMD"`.
- Với dịch vụ khác chỉ cần set `APP_CMD` + biến kết nối DB, không phải sửa script lõi.

### C. Cơ chế readiness/liveness tiêu chuẩn

- Bổ sung script `healthcheck.sh` trả mã:
  - `0`: tailscale up + consul reachable + litefs mounted.
  - `1`: chưa sẵn sàng.
- Khai báo `HEALTHCHECK` trong Dockerfile để tích hợp orchestrator.

### D. Tăng tính production-ready

1. Verify checksum/signature cho binary tải về.
2. Pin version qua build args + changelog rõ ràng.
3. Thêm backup sidecar hoặc cron snapshot.
4. Structured logs và metric export.
5. Tài liệu `ENV CONTRACT` (bảng env bắt buộc/tùy chọn, default, ví dụ).

## Lộ trình triển khai gọn (ít đụng code)

- **Phase 1 (nhanh):** env hóa các giá trị hard-code (`bootstrap-expect`, consul key, app cmd).
- **Phase 2:** thêm `healthcheck.sh` + Docker `HEALTHCHECK` + tài liệu ENV.
- **Phase 3:** hardening binary download + backup/restore + monitoring.

## Kết luận

Codebase hiện tại phù hợp để **POC/ demo failover** và đã có nền tảng tốt. Để vận hành production và đóng gói “1 image dùng lại nhiều dịch vụ”, cần chuyển toàn bộ điểm cố định sang cấu hình ENV, bổ sung healthcheck/observability/backup, và chuẩn hóa contract tích hợp để đội khác chỉ cần truyền biến môi trường là chạy.
