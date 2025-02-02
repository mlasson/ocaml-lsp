open Types
module String = StringLabels

exception Invalid_utf8

exception Outside

let find_nth_nl =
  let rec find_nth_nl str nth pos len =
    if nth = 0 then pos
    else if pos >= len then raise Outside
    else if str.[pos] = '\n' then find_nth_nl str (nth - 1) (pos + 1) len
    else find_nth_nl str nth (pos + 1) len
  in
  fun s ~nth ~start ->
    let len = String.length s in
    match find_nth_nl s nth start len with
    | n -> n
    | exception Outside -> len

let find_utf8_pos =
  let rec find_pos char dec =
    if char = 0 || Uutf.decoder_line dec = 2 then Uutf.decoder_byte_count dec
    else
      match Uutf.decode dec with
      | `Malformed _ | `Await -> raise Invalid_utf8
      | `End -> assert false
      | `Uchar _ -> find_pos (char - 1) dec
  in
  fun s ~start ~character ->
    let dec =
      Uutf.decoder ~nln:(`ASCII (Uchar.of_char '\n')) ~encoding:`UTF_8 `Manual
    in
    Uutf.Manual.src
      dec
      (Bytes.unsafe_of_string s)
      start
      (String.length s - start);
    assert (Uutf.decoder_line dec = 1);
    find_pos character dec + start

let find_offset_8 ~utf8 ~utf8_range:range =
  let { Range.start; end_ } = range in
  let start_line_offset = find_nth_nl utf8 ~nth:start.line ~start:0 in
  let end_line_offset =
    if end_.line = start.line then start_line_offset
    else if end_.line > start.line then
      find_nth_nl utf8 ~nth:(end_.line - start.line) ~start:start_line_offset
    else invalid_arg "inverted range"
  in
  let make_offset ~start ~character =
    if start = String.length utf8 then start
    else find_utf8_pos utf8 ~start ~character
  in
  let start_offset =
    make_offset ~start:start_line_offset ~character:start.character
  in
  let end_offset =
    make_offset ~start:end_line_offset ~character:end_.character
  in
  (start_offset, end_offset)

let find_offset_16 ~utf8 ~utf16_range:range =
  let dec =
    Uutf.decoder
      ~nln:(`ASCII (Uchar.of_char '\n'))
      ~encoding:`UTF_8
      (`String utf8)
  in
  let utf16_codepoint_size = 4 in
  let utf16_codepoints_buf = Bytes.create utf16_codepoint_size in
  let enc = Uutf.encoder `UTF_16LE `Manual in
  let rec find_char line char =
    if char = 0 || Uutf.decoder_line dec = line + 2 then
      Uutf.decoder_byte_count dec
    else
      match Uutf.decode dec with
      | `Await -> raise Invalid_utf8
      | `End -> Uutf.decoder_byte_count dec
      | `Malformed _ ->
        invalid_arg "Text_document.find_offset: utf8 string is malformed"
      | `Uchar _ as u ->
        Uutf.Manual.dst enc utf16_codepoints_buf 0 utf16_codepoint_size;
        (match Uutf.encode enc u with
        | `Partial ->
          (* we always have space for one character *)
          assert false
        | `Ok -> ());
        let char =
          let bytes_read = utf16_codepoint_size - Uutf.Manual.dst_rem enc in
          char - (bytes_read / 2)
        in
        find_char line char
  in
  let rec find_pos (pos : Position.t) =
    if Uutf.decoder_line dec = pos.line + 1 then
      find_char pos.line pos.character
    else
      match Uutf.decode dec with
      | `Uchar _ -> find_pos pos
      | `Malformed _ | `Await -> raise Invalid_utf8
      | `End -> Uutf.decoder_byte_count dec
  in
  let { Range.start; end_ } = range in
  let start_offset = find_pos start in
  let end_offset =
    if start = end_ then start_offset
    else if start.line = end_.line then
      find_char start.line (end_.character - start.character)
    else find_pos end_
  in
  (start_offset, end_offset)

(* Text is received as UTF-8. However, the protocol specifies offsets should be
   computed based on UTF-16. Therefore we reencode every file into utf16 for
   analysis. *)

type t =
  { document : TextDocumentItem.t
  ; position_encoding : [ `UTF8 | `UTF16 ]
  }

let text (t : t) = t.document.text

let make ~position_encoding (t : DidOpenTextDocumentParams.t) =
  { document = t.textDocument; position_encoding }

let documentUri (t : t) = t.document.uri

let version (t : t) = t.document.version

let languageId (t : t) = t.document.languageId

let apply_content_change ?version (t : t)
    (change : TextDocumentContentChangeEvent.t) =
  let document =
    match change.range with
    | None -> { t.document with text = change.text }
    | Some range ->
      let start_offset, end_offset =
        let utf8 = t.document.text in
        match t.position_encoding with
        | `UTF16 -> find_offset_16 ~utf8 ~utf16_range:range
        | `UTF8 -> find_offset_8 ~utf8 ~utf8_range:range
      in
      let text =
        String.concat
          ~sep:""
          [ String.sub t.document.text ~pos:0 ~len:start_offset
          ; change.text
          ; String.sub
              t.document.text
              ~pos:end_offset
              ~len:(String.length t.document.text - end_offset)
          ]
      in
      { t.document with text }
  in
  let document =
    match version with
    | None -> document
    | Some version -> { document with version }
  in
  { t with document }
