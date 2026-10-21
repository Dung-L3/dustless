import type { Reason, ReasonCode } from "../types.ts";

const TEMPLATES: Record<ReasonCode, string> = {
  min_age: "mới {age} ngày, rule yêu cầu ≥ {min} ngày",
  stale_days: "mới {age} ngày, rule yêu cầu ≥ {min} ngày",
  verify_failed: "KHÔNG XÓA: {cause}",
  busy_process: "{names} đang chạy, bỏ qua để tránh hỏng tiến trình đang dùng",
  listing_unavailable: "không liệt kê được tiến trình đang chạy, bỏ qua để tránh hỏng tiến trình đang dùng",
  not_determinable:
    "không xác định được tiến trình {names} đang chạy, bỏ qua để tránh hỏng tiến trình đang dùng",
  revalidate_age: "bỏ qua: cây cache đã bị chạm sau lúc quét (mới {age} ngày, rule yêu cầu ≥ {min} ngày)",
  revalidate_verify: "bỏ qua: {cause}",
  not_selected: "không được chọn: ngoài danh sách --only-file",
  needs_confirmation: "cần xác nhận, chạy lại với --yes",
  declined: "người dùng từ chối",
  missing: "bỏ qua: đường dẫn không còn tồn tại",
  red_list: "từ chối: nằm trong danh sách đỏ",
  home: "từ chối: là HOME hoặc thư mục cha của HOME",
  root: "từ chối: filesystem root",
  protected: "từ chối: là HOME, thư mục cha của HOME hoặc gốc hệ thống",
  symlink: "từ chối: đường dẫn đi qua liên kết tượng trưng",
  unresolvable: "từ chối: không xác minh được đường dẫn thực",
  changed: "từ chối: đường dẫn thay đổi trong lúc chờ xoá",
  io_error: "{code}: {message}",
  outside_roots: "ngoài các thư mục đã quét",
  not_executable: "không phải tệp thực thi",
  not_a_regular_file: "không phải tệp thường",
  engine_unavailable: "không chạy được engine",
  confirm_required: "cần xác nhận",
  not_an_app: "không phải gói .app",
  system_app: "từ chối: ứng dụng hệ thống",
  not_allowed_dir: "từ chối: ứng dụng không nằm trong thư mục được phép",
  denied_path: "từ chối: đường dẫn bị chặn",
  no_bundle_id: "không đọc được bundle id",
  bad_bundle_id: "bundle id \"{id}\" không hợp lệ",
  leftover_escapes_home: "từ chối: đường dẫn file liên quan ra ngoài HOME",
  not_a_leftover: "từ chối: không phải file liên quan hợp lệ của ứng dụng này",
  not_found: "bỏ qua: đường dẫn không còn tồn tại",
  moved_to_trash: "đã chuyển vào {path}",
  purged: "đã xoá vĩnh viễn",
};

export function describeReason(reason: Reason | null | undefined): string {
  if (!reason) return "";
  const template = TEMPLATES[reason.code] ?? reason.code;
  return template.replace(/\{(\w+)\}/g, (_match, key: string) => reason.params?.[key] ?? "");
}

export function reason(code: ReasonCode, params?: Record<string, string>): Reason {
  return params ? { code, params } : { code };
}
