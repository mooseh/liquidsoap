open MetadataBase
module R = Reader

let read_size ~synch_safe f =
  let s = R.read f 4 in
  let s0 = int_of_char s.[0] in
  let s1 = int_of_char s.[1] in
  let s2 = int_of_char s.[2] in
  let s3 = int_of_char s.[3] in
  if synch_safe then (
    if s0 lor s1 lor s2 lor s3 land 0b10000000 <> 0 then raise Invalid;
    (s0 lsl 21) + (s1 lsl 14) + (s2 lsl 7) + s3)
  else (s0 lsl 24) + (s1 lsl 16) + (s2 lsl 8) + s3

let read_size_v2 f =
  let s = R.read f 3 in
  let s0 = int_of_char s.[0] in
  let s1 = int_of_char s.[1] in
  let s2 = int_of_char s.[2] in
  (s0 lsl 16) + (s1 lsl 8) + s2

let recode enc =
  if enc = 0 then CharEncoding.convert CharEncoding.iso8859 CharEncoding.utf8
  else if enc = 1 || enc = 2 then
    CharEncoding.convert CharEncoding.utf16 CharEncoding.utf8
  else if enc = 3 then fun s -> s
  else fun s -> s

let normalize_id = function
  | "COMM" -> "comment"
  | "TALB" -> "album"
  | "TBPM" -> "tempo"
  | "TCON" -> "content"
  | "TENC" -> "encoder"
  | "TDAT" -> "date"
  | "TIT2" -> "title"
  | "TLAN" -> "language"
  | "TLEN" -> "length"
  | "TPE1" -> "artist"
  | "TPE2" -> "band"
  | "TPUB" -> "publisher"
  | "TRCK" -> "tracknumber"
  | "TSSE" -> "encoder"
  | "TYER" -> "year"
  | "WXXX" -> "url"
  | id -> id

(** Parse ID3v2 tags. *)
let parse f : metadata =
  let id = R.read f 3 in
  if id <> "ID3" then raise Invalid;
  let version =
    let v1 = R.byte f in
    let v2 = R.byte f in
    [| 2; v1; v2 |]
  in
  let v = version.(1) in
  if not (List.mem v [2; 3; 4]) then raise Invalid;
  let id_len, read_frame_size =
    if v = 2 then (3, read_size_v2) else (4, read_size ~synch_safe:(v > 3))
  in
  let flags = R.byte f in
  let unsynchronization = flags land 0b10000000 <> 0 in
  if unsynchronization then failwith "Unsynchronized headers not handled.";
  let extended_header = flags land 0b1000000 <> 0 in
  let size = read_size ~synch_safe:true f in
  let len = ref size in
  if extended_header then (
    let size = read_size ~synch_safe:(v > 3) f in
    let size = if v = 3 then size else size - 4 in
    len := !len - (size + 4);
    ignore (R.read f size));
  let tags = ref [] in
  while !len > 0 do
    try
      let id = R.read f id_len in
      if id = "\000\000\000\000" || id = "\000\000\000" then len := 0
        (* stop tag *)
      else (
        let size = read_frame_size f in
        (* make sure that we remain within the bounds in case of a problem *)
        let size = min size (!len - 10) in
        let flags = if v = 2 then None else Some (R.read f 2) in
        let data = R.read f size in
        len := !len - (size + 10);
        let compressed =
          match flags with
            | None -> false
            | Some flags -> int_of_char flags.[1] land 0b10000000 <> 0
        in
        let encrypted =
          match flags with
            | None -> false
            | Some flags -> int_of_char flags.[1] land 0b01000000 <> 0
        in
        if compressed || encrypted then raise Exit;
        if id.[0] = 'T' then (
          let encoding = int_of_char data.[0] in
          let recode = recode encoding in
          let start, len =
            match encoding with
              | 0x00 (* ISO-8859-1 *) | 0x03 (* UTF8 *) ->
                  if data.[size - 1] = '\000' then (1, size - 2)
                  else (1, size - 1)
              | 0x01 (* 16-bit unicode 2.0 *) | 0x02 (* UTF-16BE *) ->
                  if
                    size >= 2
                    && data.[size - 2] = '\000'
                    && data.[size - 1] = '\000'
                  then (1, size - 3)
                  else (1, size - 1)
              | _ -> (0, size)
          in
          let text = String.sub data start len in
          let text = recode text in
          let id, text =
            if id = "TXXX" && String.contains text '\000' then (
              let n = String.index text '\000' in
              ( String.sub text 0 n,
                String.sub text (n + 1) (String.length text - (n + 1)) ))
            else (id, text)
          in
          tags := (normalize_id id, text) :: !tags)
        else tags := (normalize_id id, data) :: !tags)
    with Exit -> ()
  done;
  !tags

let parse_file = R.with_file parse

(** APIC data. *)
type apic = {
  mime : string;
  picture_type : int;
  description : string;
  data : string;
}

type pic = {
  pic_format : string;
  pic_type : int;
  pic_description : string;
  pic_data : string;
}

(** Parse APIC data. *)
let parse_apic apic =
  let text_encoding = int_of_char apic.[0] in
  let text_bytes = if text_encoding = 1 || text_encoding = 2 then 2 else 1 in
  let recode = recode text_encoding in
  let n = String.index_from apic 1 '\000' in
  let mime = String.sub apic 1 (n - 1) in
  let n = n + 1 in
  let picture_type = int_of_char apic.[n] in
  let n = n + 1 in
  let l =
    Int.find (fun i ->
        i mod text_bytes = 0
        && apic.[n + i] = '\000'
        && (text_bytes = 1 || apic.[n + i + 1] = '\000'))
  in
  let description = recode (String.sub apic n l) in
  let n = n + l + text_bytes in
  let data = String.sub apic n (String.length apic - n) in
  { mime; picture_type; description; data }

let parse_pic pic =
  let text_encoding = int_of_char pic.[0] in
  let text_bytes = if text_encoding = 1 || text_encoding = 2 then 2 else 1 in
  let recode = recode text_encoding in
  let pic_format = String.sub pic 1 3 in
  let pic_type = int_of_char pic.[4] in
  let l =
    Int.find (fun i ->
        i mod text_bytes = 0
        && pic.[5 + i] = '\000'
        && (text_bytes = 1 || pic.[5 + i + 1] = '\000'))
  in
  let pic_description = recode (String.sub pic 5 l) in
  let n = 5 + l + text_bytes in
  let pic_data = String.sub pic n (String.length pic - n) in
  { pic_format; pic_type; pic_description; pic_data }
