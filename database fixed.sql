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
-- Giá gói theo giờ là GIÁ GỐC. Giao diện (index.html) tự động giảm 40%
-- cho các gói từ 6 giờ trở lên (logic tính giá DUY NHẤT nằm ở hàm
-- getPackagePrice() trong index.html — không tính riêng ở nơi khác).
-- =========================================================
insert into public.accounts (id, name, status, prices, sort_order) values
  ('acc1','Acc 1','available','{"1":30000,"2":50000,"3":60000,"4":80000,"6":150000,"12":280000,"24":500000,"48":900000,"72":1300000}',1),
  ('acc2','Acc 2','available','{"1":35000,"2":60000,"3":70000,"4":90000,"6":170000,"12":320000,"24":580000,"48":1050000,"72":1500000}',2),
  ('acc3','Acc 3','available','{"1":30000,"2":50000,"3":60000,"4":80000,"6":150000,"12":280000,"24":500000,"48":900000,"72":1300000}',3),
  ('acc4','Acc 4','available','{"1":25000,"2":40000,"3":50000,"4":70000,"6":130000,"12":240000,"24":440000,"48":800000,"72":1150000}',4),
  ('acc5','Acc 5','available','{"1":30000,"2":50000,"3":60000,"4":80000,"6":150000,"12":280000,"24":500000,"48":900000,"72":1300000}',5),
  ('acc6','Acc 6','available','{"1":20000,"2":40000,"3":50000,"4":60000,"6":110000,"12":200000,"24":360000,"48":650000,"72":950000}',6)
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

-- BUG FIX: trên Supabase, extension pgcrypto (hàm crypt()) thường nằm ở
-- schema "extensions", không phải "public". search_path trước đây chỉ có
-- "public" khiến hàm không thấy crypt() => lỗi "function crypt(text, text)
-- does not exist" (42883) khi tạo/gọi hàm. Thêm "extensions" vào search_path
-- để hàm tìm thấy crypt() dù pgcrypto được cài ở schema nào.
create or replace function public.verify_admin_login(p_username text, p_password text)
returns boolean
language sql
security definer
set search_path = public, extensions
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



-- =========================================================
-- MIGRATION 5 — HỆ THỐNG ĐẶT LỊCH (BOOKING) THEO KHUNG GIỜ
-- Bổ sung: bookings, booking_logs, booking_history
-- Idempotent — an toàn chạy lại nhiều lần, không mất dữ liệu cũ,
-- không đổi logic các bảng hiện có (accounts/orders/payments/rentals
-- không bị chỉnh sửa cấu trúc hay dữ liệu).
--
-- Chống trùng lịch (Race Condition) được đảm bảo ở TẦNG DATABASE
-- bằng EXCLUDE CONSTRAINT (GiST), không chỉ dựa vào kiểm tra ở
-- JavaScript — nên kể cả 2 khách bấm đặt cùng lúc, Postgres sẽ tự
-- chặn giao dịch trùng giờ, không cần transaction thủ công phía client.
-- =========================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------
-- 5.1 BẢNG bookings — lịch đặt theo khung giờ cho từng account
-- ---------------------------------------------------------
create table if not exists public.bookings (
  id              uuid primary key default gen_random_uuid(),
  code            text unique,
  account_id      text not null references public.accounts(id) on delete restrict,
  account_name    text not null,
  customer_name   text not null default '',
  phone           text not null default '',
  telegram        text not null default '',
  zalo            text not null default '',
  start_time      timestamptz not null,
  end_time        timestamptz not null,
  duration_hours  numeric not null,
  amount          numeric not null default 0,
  status          text not null default 'pending'
                  check (status in ('pending','confirmed','active','completed','cancelled')),
  order_id        uuid references public.orders(id) on delete set null,
  notes           text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint bookings_time_valid check (end_time > start_time)
);

-- Cột range dùng cho exclusion constraint (không lưu trùng dữ liệu,
-- chỉ là generated column tính từ start_time/end_time)
alter table public.bookings
  add column if not exists time_range tstzrange
  generated always as (tstzrange(start_time, end_time, '[)')) stored;

-- CHẶN TRÙNG LỊCH Ở TẦNG DATABASE: cùng 1 account, thời gian giao nhau,
-- và trạng thái còn "chiếm chỗ" (pending/confirmed/active) thì không
-- được phép tồn tại 2 booking chồng nhau, kể cả khi 2 request đến
-- đồng thời (race condition an toàn tuyệt đối, do Postgres tự khoá).
-- removed drop index bookings_no_overlap
alter table public.bookings drop constraint if exists bookings_no_overlap;
alter table public.bookings add constraint bookings_no_overlap
  exclude using gist (
    account_id with =,
    time_range with &&
  ) where (status in ('pending','confirmed','active'));

create index if not exists idx_bookings_account on public.bookings(account_id);
create index if not exists idx_bookings_status  on public.bookings(status);
create index if not exists idx_bookings_code    on public.bookings(code);
create index if not exists idx_bookings_start   on public.bookings(start_time);
create index if not exists idx_bookings_phone   on public.bookings(phone);

drop trigger if exists trg_bookings_updated_at on public.bookings;
create trigger trg_bookings_updated_at
  before update on public.bookings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------
-- 5.2 BẢNG booking_logs — nhật ký thao tác trên từng booking
-- ---------------------------------------------------------
create table if not exists public.booking_logs (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references public.bookings(id) on delete cascade,
  action       text not null,
  detail       jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists idx_booking_logs_booking on public.booking_logs(booking_id);

-- ---------------------------------------------------------
-- 5.3 BẢNG booking_history — lưu vết booking đã kết thúc/huỷ,
-- dùng cho Tra cứu (lịch sử Booking) trong Dashboard
-- ---------------------------------------------------------
create table if not exists public.booking_history (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null,
  code            text,
  account_id      text not null,
  account_name    text not null,
  customer_name   text not null default '',
  phone           text not null default '',
  telegram        text not null default '',
  zalo            text not null default '',
  start_time      timestamptz not null,
  end_time        timestamptz not null,
  duration_hours  numeric not null,
  amount          numeric not null default 0,
  final_status    text not null,
  created_at      timestamptz not null default now()
);
create index if not exists idx_booking_history_booking on public.booking_history(booking_id);
create index if not exists idx_booking_history_account on public.booking_history(account_id);
create index if not exists idx_booking_history_phone   on public.booking_history(phone);

-- ---------------------------------------------------------
-- 5.4 TRIGGER: khi booking chuyển sang completed/cancelled,
-- tự copy snapshot sang booking_history + ghi log (không phải xử lý
-- ở JS để đảm bảo không bao giờ bị bỏ sót nếu client lỗi/mất mạng)
-- ---------------------------------------------------------
create or replace function public.fn_booking_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into public.booking_logs (booking_id, action, detail)
    values (
      new.id,
      'status_change',
      jsonb_build_object('from', old.status, 'to', new.status)
    );

    if new.status in ('completed','cancelled') then
      insert into public.booking_history (
        booking_id, code, account_id, account_name, customer_name,
        phone, telegram, zalo, start_time, end_time, duration_hours,
        amount, final_status
      ) values (
        new.id, new.code, new.account_id, new.account_name, new.customer_name,
        new.phone, new.telegram, new.zalo, new.start_time, new.end_time,
        new.duration_hours, new.amount, new.status
      );
    end if;

    if new.status = 'pending' and old.status is null then
      null; -- insert case handled by fn_booking_insert_log
    end if;

    insert into public.notifications (type, message)
    values (
      case new.status
        when 'confirmed' then 'booking_confirmed'
        when 'cancelled' then 'booking_cancelled'
        when 'active' then 'booking_active'
        when 'completed' then 'booking_completed'
        else 'booking_update'
      end,
      case new.status
        when 'confirmed' then 'Booking ' || coalesce(new.code,'') || ' đã được xác nhận'
        when 'cancelled' then 'Booking ' || coalesce(new.code,'') || ' đã bị huỷ'
        when 'active' then 'Booking ' || coalesce(new.code,'') || ' đã bắt đầu thuê'
        when 'completed' then 'Booking ' || coalesce(new.code,'') || ' đã hoàn tất'
        else 'Booking ' || coalesce(new.code,'') || ' cập nhật trạng thái'
      end
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_booking_status_change on public.bookings;
create trigger trg_booking_status_change
  after update on public.bookings
  for each row execute function public.fn_booking_status_change();

create or replace function public.fn_booking_insert_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.booking_logs (booking_id, action, detail)
  values (new.id, 'created', jsonb_build_object(
    'account_id', new.account_id,
    'start_time', new.start_time,
    'end_time', new.end_time,
    'duration_hours', new.duration_hours
  ));
  insert into public.notifications (type, message)
  values ('booking_created', 'Có booking mới: ' || coalesce(new.code,'') || ' — ' || new.account_name);
  return new;
end;
$$;

drop trigger if exists trg_booking_insert_log on public.bookings;
create trigger trg_booking_insert_log
  after insert on public.bookings
  for each row execute function public.fn_booking_insert_log();

-- ---------------------------------------------------------
-- 5.5 RPC create_booking — tạo booking an toàn tuyệt đối trước
-- race condition. Nếu 2 khách đặt trùng giờ cùng lúc, giao dịch
-- đến sau sẽ nhận lỗi rõ ràng (SQLSTATE 23P01) thay vì tạo ra
-- 2 booking chồng chéo.
-- ---------------------------------------------------------
create or replace function public.create_booking(
  p_account_id     text,
  p_account_name   text,
  p_customer_name  text,
  p_phone          text,
  p_telegram       text,
  p_zalo           text,
  p_start_time     timestamptz,
  p_end_time       timestamptz,
  p_duration_hours numeric,
  p_amount         numeric,
  p_notes          text default ''
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
  v_code    text;
begin
  if p_end_time <= p_start_time then
    raise exception 'INVALID_TIME_RANGE' using errcode = '22007';
  end if;

  v_code := 'BK' || to_char(now(), 'YYMMDD') || lpad(floor(random()*10000)::text, 4, '0');

  begin
    insert into public.bookings (
      code, account_id, account_name, customer_name, phone, telegram, zalo,
      start_time, end_time, duration_hours, amount, notes, status
    ) values (
      v_code, p_account_id, p_account_name, p_customer_name, p_phone, p_telegram, p_zalo,
      p_start_time, p_end_time, p_duration_hours, p_amount, p_notes, 'pending'
    )
    returning * into v_booking;
  exception
    when exclusion_violation then
      raise exception 'BOOKING_TIME_CONFLICT' using errcode = '23P01';
  end;

  return v_booking;
end;
$$;

grant execute on function public.create_booking(text,text,text,text,text,text,timestamptz,timestamptz,numeric,numeric,text) to anon, authenticated;

-- ---------------------------------------------------------
-- 5.6 RPC extend_booking — gia hạn booking nếu phía sau còn trống.
-- Dựa vào chính EXCLUDE CONSTRAINT ở trên để đảm bảo an toàn: nếu
-- khung giờ mới đè lên booking khác, update sẽ tự bị Postgres từ
-- chối (23P01) mà không cần kiểm tra thủ công trước.
-- ---------------------------------------------------------
create or replace function public.extend_booking(
  p_booking_id uuid,
  p_extra_hours numeric
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings;
begin
  begin
    update public.bookings
    set end_time = end_time + make_interval(secs => p_extra_hours * 3600),
        duration_hours = duration_hours + p_extra_hours
    where id = p_booking_id
      and status in ('pending','confirmed','active')
    returning * into v_booking;
  exception
    when exclusion_violation then
      raise exception 'BOOKING_TIME_CONFLICT' using errcode = '23P01';
  end;

  if v_booking.id is null then
    raise exception 'BOOKING_NOT_FOUND_OR_CLOSED' using errcode = 'P0002';
  end if;

  insert into public.booking_logs (booking_id, action, detail)
  values (p_booking_id, 'extended', jsonb_build_object('extra_hours', p_extra_hours));

  return v_booking;
end;
$$;

grant execute on function public.extend_booking(uuid, numeric) to anon, authenticated;

-- ---------------------------------------------------------
-- 5.7 RPC check_account_availability — trả về danh sách các
-- booking đang chiếm chỗ của 1 account trong 1 khoảng thời gian,
-- dùng để vẽ Timeline (🟢 Trống / 🟡 Đã đặt / 🔴 Đang thuê) phía JS.
-- ---------------------------------------------------------
create or replace function public.check_account_availability(
  p_account_id text,
  p_from       timestamptz,
  p_to         timestamptz
)
returns setof public.bookings
language sql
security definer
set search_path = public
as $$
  select * from public.bookings
  where account_id = p_account_id
    and status in ('pending','confirmed','active')
    and time_range && tstzrange(p_from, p_to, '[)')
  order by start_time asc;
$$;

grant execute on function public.check_account_availability(text, timestamptz, timestamptz) to anon, authenticated;

-- ---------------------------------------------------------
-- 5.8 RLS — cùng mô hình mở như các bảng hiện có (kiểm tra logic
-- nằm ở JS/RPC phía client, không đổi mô hình bảo mật hiện tại)
-- ---------------------------------------------------------
alter table public.bookings         enable row level security;
alter table public.booking_logs     enable row level security;
alter table public.booking_history  enable row level security;

drop policy if exists bookings_select_all on public.bookings;
create policy bookings_select_all on public.bookings for select using (true);
drop policy if exists bookings_write_all on public.bookings;
create policy bookings_write_all on public.bookings for all using (true) with check (true);

drop policy if exists booking_logs_select_all on public.booking_logs;
create policy booking_logs_select_all on public.booking_logs for select using (true);
drop policy if exists booking_logs_write_all on public.booking_logs;
create policy booking_logs_write_all on public.booking_logs for all using (true) with check (true);

drop policy if exists booking_history_select_all on public.booking_history;
create policy booking_history_select_all on public.booking_history for select using (true);
drop policy if exists booking_history_write_all on public.booking_history;
create policy booking_history_write_all on public.booking_history for all using (true) with check (true);

-- ---------------------------------------------------------
-- 5.9 REALTIME — bật đồng bộ tức thời cho 3 bảng mới
-- ---------------------------------------------------------
do $$
begin
  begin
    alter publication supabase_realtime add table public.bookings;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.booking_logs;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.booking_history;
  exception when duplicate_object then null;
  end;
end $$;

-- =========================================================
-- HẾT MIGRATION 5 — Sau khi chạy, vào Database > Replication
-- và bật Realtime cho bookings, booking_logs, booking_history
-- nếu chưa tự bật.
-- =========================================================

-- =========================================================
-- MIGRATION 6 — Ribbon (HOT/VIP/NEW/SALE) hiển thị trên Card Account
-- Idempotent, additive, không mất dữ liệu.
-- =========================================================
alter table public.accounts add column if not exists ribbon text;
alter table public.accounts drop constraint if exists accounts_ribbon_check;
alter table public.accounts add constraint accounts_ribbon_check
  check (ribbon is null or ribbon in ('HOT','VIP','NEW','SALE'));
