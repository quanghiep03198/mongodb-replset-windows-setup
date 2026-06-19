# MongoDB Replica Set Setup (Windows)

Script `ReplSet.ps1` giúp dựng nhanh replica set 3 node (Primary, Secondary, Arbiter) trên máy Windows, có hỗ trợ cài Windows service.

## 1. Yêu cầu hệ thống

- Windows PowerShell 5.1+ hoặc PowerShell 7+
- MongoDB Server đã cài trên máy
- `mongod.exe` có thể truy cập qua `PATH` hoặc biến môi trường
- Khuyến nghị có `mongosh.exe` (để `initiate`/`verify` replica set đầy đủ)
- Quyền Administrator nếu muốn cài/start Windows service

## 2. Cấu trúc thư mục khuyến nghị

Ví dụ thư mục base là `C:\Program Files\MongoDB\Server\8.x\rs0`:

```text
C:\Program Files\MongoDB\Server\8.x\rs0
|- ReplSet.ps1
|- 27017
|  |- bin
|  |  \- mongod.conf
|- 27018
|  |- bin
|  |  \- mongod.conf
\- 27019
    |- bin
    \- mongod.conf
```

Trong mỗi file `mongod.conf` cần có:

- `replication.replSetName` giống nhau (ví dụ `rs0`)
- `net.port` tương ứng `27017`, `27018`, `27019`

## 3. Biến môi trường (khuyến nghị)

Bạn có thể set một trong các biến sau:

- `MONGO_HOME`
- `MONGODB_HOME`
- `MONGODB_BIN`

Ví dụ (PowerShell):

```powershell
$env:MONGO_HOME = "C:\Program Files\MongoDB\Server\8.x"
```

Hoặc set vĩnh viễn:

```powershell
setx MONGO_HOME "C:\Program Files\MongoDB\Server\8.x"
```

Script sẽ tự dò executable theo thứ tự:

1. `PATH`
2. `server bin` theo `BasePath` (thư mục cha của `BasePath` + `\bin`)
3. Các biến môi trường ở trên
4. Fallback local của node `27017\bin`

## 4. Cách chạy cơ bản

Trường hợp script nằm trong đúng thư mục base (ví dụ `...\rs0`):

```powershell
.\ReplSet.ps1
```

Trường hợp script đặt ở thư mục khác:

```powershell
.\ReplSet.ps1 -BasePath "C:\Program Files\MongoDB\Server\8.3\rs0"
```

## 5. Chạy không cài service (test trước)

Dùng mode này để kiểm tra logic start node + initiate replica set trước khi cài service.

```powershell
.\ReplSet.ps1 -BasePath "C:\Program Files\MongoDB\Server\8.3\rs0" -SkipServiceInstall
```

## 6. Tên service được cài

Script cài 3 service như sau:

- `ServiceName: mongo-primary`, `DisplayName: MongoDB Primary`
- `ServiceName: mongo-secondary`, `DisplayName: MongoDB Secondary`
- `ServiceName: mongo-arbiter`, `DisplayName: MongoDB Arbiter`

## 7. Tham số hỗ trợ

- `BasePath`: đường dẫn thư mục chứa 3 node `27017/27018/27019`
- `ReplicaSetName`: tên replica set, mặc định `rs0`
- `PrimaryHost`: host kết nối, mặc định `127.0.0.1`
- `PrimaryPort`: mặc định `27017`
- `SecondaryPort`: mặc định `27018`
- `ArbiterPort`: mặc định `27019`
- `StartupTimeoutSec`: timeout chờ node sẵn sàng, mặc định `120` giây
- `SkipServiceInstall`: bỏ qua bước cài/start service

Ví dụ:

```powershell
.\ReplSet.ps1 `
   -BasePath "C:\Program Files\MongoDB\Server\8.3\rs0" `
   -ReplicaSetName "rs0" `
   -PrimaryHost "127.0.0.1" `
   -PrimaryPort 27017 `
   -SecondaryPort 27018 `
   -ArbiterPort 27019 `
   -StartupTimeoutSec 180
```

## 8. Log output

Script ghi log vào file:

```text
replset-setup.log
```

Log có từng step để dễ xác định lỗi.

## 9. Lỗi thường gặp và cách xử lý

### Cannot find mongod

Nguyên nhân:

- Chưa set `PATH`/biến môi trường đúng
- Sai thư mục MongoDB `bin`

Cách xử lý:

- Xác nhận `mongod.exe` tồn tại
- Set `MONGO_HOME`/`MONGODB_HOME`/`MONGODB_BIN` đúng
- Chạy lại script

### Cannot find mongosh

Script vẫn có thể chạy start/service, nhưng sẽ skip initiate/verify replica set khi không có `mongosh`.

Khuyến nghị cài `mongosh` để chạy đầy đủ bước Step 2-5 và Step 10.

### This node was not started with replication enabled

Nguyên nhân:

- Node đang chạy standalone, không có `replSet`

Script đã có logic restart node với `--replSet` khi cần.

Nếu vẫn lặp, kiểm tra file `mongod.conf` của node đó và log mongod tương ứng trong thư mục log của node.

### Please run PowerShell as Administrator

Xuất hiện khi đến bước cài service.

Mở PowerShell bằng **Run as Administrator** rồi chạy lại.

## 10. Lưu ý triển khai máy khác

Chỉ cần copy:

- `ReplSet.ps1`
- Cấu trúc thư mục `27017/27018/27019`
- Các file `mongod.conf` tương ứng

Sau đó:

1. Chỉnh `BasePath` hoặc đặt script ngay trong thư mục base
2. Đảm bảo máy đích có `mongod` (và `mongosh` nếu muốn full verify)
3. Chạy test trước bằng `-SkipServiceInstall`, sau đó chạy full để cài service
