-- =========================================================
-- ACC VAULT — SUPABASE DATABASE SCHEMA (DATA-ONLY VERSION)
-- Chạy toàn bộ file này trong Supabase SQL Editor (1 lần).
-- An toàn để chạy lại nhiều lần (idempotent).
-- Toàn bộ logic nghiệp vụ (tạo mã thuê, kiểm tra acc, countdown,
-- đồng bộ trạng thái, xác nhận thanh toán, gia hạn...) xử lý ở
-- JavaScript trong index.html thông qua Supabase JS Client API
-- (select / insert / update / delete trực tiếp).
-- Database CHỈ lưu dữ liệu: bảng, khóa, index, RLS.
-- =========================================================

create extension if not exists pgcrypto;

-- =========================================================
-- 1. BẢNG accounts — danh sách acc cho thuê
-- =========================================================
create table if not exists public.accounts (
  id           text primary key,
  name         text not null,
  status       text not null default 'available'
               check (status in ('available','rented','maintenance')),
  prices       jsonb not null default '{}'::jsonb,
  sort_order   int not null default 0,
  updated_at   timestamptz not null default now()
);

-- =========================================================
-- 2. BẢNG orders — đơn thuê
-- =========================================================
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  code           text unique,
  account_id     text not null references public.accounts(id) on delete restrict,
  account_name   text not null,
  package_hours  int not null,
  amount         numeric not null,
  status         text not null default 'holding'
                 check (status in ('holding','unconfirmed','confirmed','rejected','expired')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz,
  confirmed_at   timestamptz
);
create index if not exists idx_orders_account on public.orders(account_id);
create index if not exists idx_orders_status  on public.orders(status);
create index if not exists idx_orders_code    on public.orders(code);

-- =========================================================
-- 3. BẢNG payments — lịch sử xác nhận thanh toán của từng đơn
-- =========================================================
create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  amount      numeric not null,
  method      text not null default 'bank_transfer',
  status      text not null default 'claimed'
              check (status in ('claimed','confirmed','rejected')),
  created_at  timestamptz not null default now()
);
create index if not exists idx_payments_order on public.payments(order_id);

-- =========================================================
-- 4. BẢNG rentals — phiên thuê thực tế
-- =========================================================
create table if not exists public.rentals (
  id           uuid primary key default gen_random_uuid(),
  account_id   text not null references public.accounts(id) on delete restrict,
  order_id     uuid not null references public.orders(id) on delete cascade,
  start_time   timestamptz not null default now(),
  end_time     timestamptz not null,
  status       text not null default 'active'
               check (status in ('active','completed','cancelled')),
  created_at   timestamptz not null default now()
);
create unique index if not exists one_active_rental_per_account
  on public.rentals(account_id) where status = 'active';
create index if not exists idx_rentals_order on public.rentals(order_id);

-- =========================================================
-- 5. BẢNG settings — cấu hình ngân hàng / zalo / logo / QR
-- =========================================================
create table if not exists public.settings (
  id                   text primary key default 'default',
  bank_name            text,
  bank_account_name    text,
  bank_account_number  text,
  zalo_number          text,
  qr_url               text,
  logo_url             text,
  updated_at           timestamptz not null default now()
);
insert into public.settings (id) values ('default')
  on conflict (id) do nothing;

-- =========================================================
-- 6. BẢNG notifications — thông báo cho Admin
-- =========================================================
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  type        text not null,
  message     text not null,
  order_id    uuid references public.orders(id) on delete set null,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists idx_notifications_read on public.notifications(is_read);

-- =========================================================
-- 7. BẢNG admin_logs — nhật ký thao tác quản trị
-- =========================================================
create table if not exists public.admin_logs (
  id          uuid primary key default gen_random_uuid(),
  action      text not null,
  detail      jsonb,
  created_at  timestamptz not null default now()
);

-- =========================================================
-- SEED DATA — 6 acc mặc định
-- =========================================================
insert into public.accounts (id, name, status, prices, sort_order) values
  ('acc1','Acc 1','available','{"1":30000,"2":50000,"3":60000,"4":80000}',1),
  ('acc2','Acc 2','available','{"1":35000,"2":60000,"3":70000,"4":90000}',2),
  ('acc3','Acc 3','available','{"1":30000,"2":50000,"3":60000,"4":80000}',3),
  ('acc4','Acc 4','available','{"1":25000,"2":40000,"3":50000,"4":70000}',4),
  ('acc5','Acc 5','available','{"1":30000,"2":50000,"3":60000,"4":80000}',5),
  ('acc6','Acc 6','available','{"1":20000,"2":40000,"3":50000,"4":60000}',6)
on conflict (id) do nothing;

update public.settings set
  bank_name = 'BIDV — PGD',
  bank_account_name = 'MAI ĐẶNG PHƯỚC THỊNH',
  bank_account_number = '8865743051',
  zalo_number = '0818105658'
where id = 'default'
  and bank_name is null;

-- =========================================================
-- updated_at TRIGGER — chỉ dùng trigger tối thiểu này (không có
-- trigger/function nghiệp vụ nào khác trong file)
-- =========================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_accounts_updated_at on public.accounts;
create trigger trg_accounts_updated_at
  before update on public.accounts
  for each row execute function public.set_updated_at();

drop trigger if exists trg_settings_updated_at on public.settings;
create trigger trg_settings_updated_at
  before update on public.settings
  for each row execute function public.set_updated_at();

-- =========================================================
-- ROW LEVEL SECURITY
-- anon/authenticated được đọc và ghi trực tiếp (insert/update/delete)
-- vì toàn bộ logic kiểm tra nằm ở JavaScript trong index.html.
-- =========================================================
alter table public.accounts      enable row level security;
alter table public.orders        enable row level security;
alter table public.payments      enable row level security;
alter table public.rentals       enable row level security;
alter table public.settings      enable row level security;
alter table public.notifications enable row level security;
alter table public.admin_logs    enable row level security;

drop policy if exists accounts_select_all on public.accounts;
create policy accounts_select_all on public.accounts for select using (true);
drop policy if exists accounts_write_all on public.accounts;
create policy accounts_write_all on public.accounts for all using (true) with check (true);

drop policy if exists orders_select_all on public.orders;
create policy orders_select_all on public.orders for select using (true);
drop policy if exists orders_write_all on public.orders;
create policy orders_write_all on public.orders for all using (true) with check (true);

drop policy if exists payments_select_all on public.payments;
create policy payments_select_all on public.payments for select using (true);
drop policy if exists payments_write_all on public.payments;
create policy payments_write_all on public.payments for all using (true) with check (true);

drop policy if exists rentals_select_all on public.rentals;
create policy rentals_select_all on public.rentals for select using (true);
drop policy if exists rentals_write_all on public.rentals;
create policy rentals_write_all on public.rentals for all using (true) with check (true);

drop policy if exists settings_select_all on public.settings;
create policy settings_select_all on public.settings for select using (true);
drop policy if exists settings_write_all on public.settings;
create policy settings_write_all on public.settings for all using (true) with check (true);

drop policy if exists notifications_select_all on public.notifications;
create policy notifications_select_all on public.notifications for select using (true);
drop policy if exists notifications_write_all on public.notifications;
create policy notifications_write_all on public.notifications for all using (true) with check (true);

drop policy if exists admin_logs_select_all on public.admin_logs;
create policy admin_logs_select_all on public.admin_logs for select using (true);
drop policy if exists admin_logs_write_all on public.admin_logs;
create policy admin_logs_write_all on public.admin_logs for all using (true) with check (true);

-- =========================================================
-- REALTIME — bật replication cho các bảng cần đồng bộ tức thời
-- =========================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.accounts;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.orders;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.rentals;
  exception when duplicate_object then null;
  end;
end $$;

-- =========================================================
-- HẾT — Sau khi chạy file này, vào Database > Replication trong Supabase
-- và đảm bảo 4 bảng accounts, orders, notifications, rentals đã bật Realtime.
-- =========================================================

-- =========================================================
-- MIGRATION 2 — bổ sung cột còn thiếu cho tính năng Gallery /
-- Mô tả / Đăng nhập Admin an toàn / Hủy đơn.
-- Idempotent — chạy lại không lỗi.
-- =========================================================

-- ---- accounts: ảnh bìa, gallery, mô tả ----
alter table public.accounts add column if not exists description text not null default '';
alter table public.accounts add column if not exists cover_url   text;
alter table public.accounts add column if not exists gallery     jsonb not null default '[]'::jsonb;

-- ---- orders: thêm trạng thái 'cancelled' cho thao tác Hủy đơn ----
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('holding','unconfirmed','confirmed','rejected','expired','cancelled'));

-- ---- storage bucket cho ảnh acc (bìa + gallery) ----
-- BUG FIX: nếu bucket 'acc-gallery' đã tồn tại từ trước (vd tạo tay ở
-- Dashboard) với public=false, "on conflict do nothing" sẽ KHÔNG bật
-- public cho bucket đó => getPublicUrl() sinh URL nhưng ảnh trả về lỗi
-- 400/403 (Bucket not found / not public) => ảnh không hiển thị trên
-- website. Sửa thành upsert để luôn ép bucket này về public = true.
insert into storage.buckets (id, name, public)
values ('acc-gallery','acc-gallery', true)
on conflict (id) do update set public = true;

drop policy if exists "acc-gallery public read" on storage.objects;
create policy "acc-gallery public read" on storage.objects
  for select using (bucket_id = 'acc-gallery');

drop policy if exists "acc-gallery public write" on storage.objects;
create policy "acc-gallery public write" on storage.objects
  for all using (bucket_id = 'acc-gallery') with check (bucket_id = 'acc-gallery');

-- ---- admin_users: xác thực đăng nhập Dashboard qua RPC, không
-- expose mật khẩu (hash) cho client, không hardcode mật khẩu trong JS ----
create table if not exists public.admin_users (
  id            uuid primary key default gen_random_uuid(),
  username      text unique not null,
  password_hash text not null,
  created_at    timestamptz not null default now()
);

-- Tài khoản mặc định: admin / password (đổi ngay sau khi đăng nhập lần đầu
-- bằng cách chạy lại lệnh update bên dưới với mật khẩu mới của bạn)
insert into public.admin_users (username, password_hash)
values ('admin', crypt('password', gen_salt('bf')))
on conflict (username) do nothing;

alter table public.admin_users enable row level security;
-- Không có policy select/write nào cho anon/authenticated => client
-- không thể đọc bảng này trực tiếp, chỉ có thể gọi qua RPC bên dưới.

create or replace function public.verify_admin_login(p_username text, p_password text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.admin_users
    where username = p_username
      and password_hash = crypt(p_password, password_hash)
  );
$$;

revoke all on public.admin_users from anon, authenticated;
grant execute on function public.verify_admin_login(text, text) to anon, authenticated;

-- BUG FIX: PostgREST chỉ cho phép gọi RPC nếu role có quyền EXECUTE
-- VÀ PostgREST role thực thi request (mặc định là "anon" cho request
-- không kèm JWT) cũng cần quyền USAGE trên schema public. Một số
-- project Supabase cũ thiếu quyền này khiến RPC báo lỗi "permission
-- denied for schema public" (code 42501) thay vì lỗi mạng thật sự.
-- Cấp lại tường minh để chắc chắn verify_admin_login luôn gọi được.
grant usage on schema public to anon, authenticated;

-- ---- đảm bảo bảng accounts cũng nằm trong Realtime publication ----
-- (đã có ở migration 1, giữ lại idempotent-safe ở đây phòng trường hợp
--  publication bị tạo lại)
do $$
begin
  begin
    alter publication supabase_realtime add table public.accounts;
  exception when duplicate_object then null;
  end;
end $$;

-- =========================================================
-- MIGRATION 3 — orders.updated_at (dùng cho cột "Ngày cập nhật"
-- trong tab Tra cứu của Dashboard)
-- =========================================================
alter table public.orders add column if not exists updated_at timestamptz not null default now();

drop trigger if exists trg_orders_updated_at on public.orders;
create trigger trg_orders_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- =========================================================
-- MIGRATION 4 — BUG FIX: bucket 'acc-gallery' có thể đã được tạo
-- thủ công trước khi chạy migration 2 (public=false theo mặc định
-- của Supabase Dashboard). Ép lại public=true một lần nữa ở đây để
-- đảm bảo ảnh cover/gallery luôn truy cập được qua getPublicUrl(),
-- kể cả trên project đã tồn tại từ trước khi có dòng "on conflict
-- do update" ở migration 2.
-- =========================================================
update storage.buckets set public = true where id = 'acc-gallery';
