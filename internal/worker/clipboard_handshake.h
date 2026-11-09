#ifndef RDP_CLIPBOARD_HANDSHAKE_H
#define RDP_CLIPBOARD_HANDSHAKE_H

#include <freerdp/server/cliprdr.h>

#include <string.h>

/* Clipboard format ids (docs/DESIGN-2026-11-08-clipboard-files.md section 2). */
#define RDP_CLIPBOARD_FORMAT_ID_TEXT 13u
#define RDP_CLIPBOARD_FORMAT_ID_FILE_GROUP_DESCRIPTOR 0xC003u
#define RDP_CLIPBOARD_FORMAT_ID_FILE_CONTENTS 0xC004u

/* Registered-format long names ([MS-RDPECLIP] 2.2.3.1.1.1 + MS-RDPECLIP
 * registered clipboard format names). Windows clients map the file formats by
 * these names: field evidence from mstsc.exe on Windows 11 (2026-11-08) shows
 * the client advertising FileGroupDescriptorW/FileContents with DYNAMIC format
 * ids (49314/49269) plus the names, and answering CB_RESPONSE_FAIL to a data
 * request for a fixed id it never advertised. The server must therefore request
 * the client-advertised id and should advertise the names itself. */
#define RDP_CLIPBOARD_FORMAT_NAME_TEXT "CF_UNICODETEXT"
#define RDP_CLIPBOARD_FORMAT_NAME_FILE_GROUP_DESCRIPTOR "FileGroupDescriptorW"
#define RDP_CLIPBOARD_FORMAT_NAME_FILE_CONTENTS "FileContents"

/* Semantic kind of the clipboard format selected from a client CB_FORMAT_LIST.
 * The worker stores this (not the wire format id) as its pending request state:
 * 0 none / 1 text / 2 files. */
#define RDP_CLIPBOARD_KIND_NONE 0u
#define RDP_CLIPBOARD_KIND_TEXT 1u
#define RDP_CLIPBOARD_KIND_FILES 2u

/* Result of scanning a client CB_FORMAT_LIST: the semantic kind plus the
 * formatId that the CLIENT advertised for the selected entry. MS-RDPECLIP
 * requires the CB_FORMAT_DATA_REQUEST to carry the advertised formatId, which
 * is a dynamic id for real Windows clients' registered file formats. */
typedef struct {
 UINT32 kind;      /* RDP_CLIPBOARD_KIND_* */
 UINT32 format_id; /* client-advertised formatId to request, 0 when none */
} rdp_clipboard_format_selection;

/* Decide which format to request from the client after its CB_FORMAT_LIST.
 * A list containing FileGroupDescriptorW (matched by format id 0xC003 or by the
 * long format name, because mstsc/the Windows App advertise both) wins over
 * text, so a Windows Explorer copy of files is treated as a file offer even if
 * the list also carries CF_UNICODETEXT. Text is matched by id 13 or by the long
 * name. The returned format_id is always the id the client advertised, never a
 * fixed id substituted by us. Returns kind=NONE/format_id=0 when the list has
 * nothing we request. */
static inline rdp_clipboard_format_selection rdp_clipboard_select_format(
    const CLIPRDR_FORMAT_LIST *formats) {
 rdp_clipboard_format_selection selected={RDP_CLIPBOARD_KIND_NONE,0u};
 rdp_clipboard_format_selection text={RDP_CLIPBOARD_KIND_TEXT,0u};
 if(!formats || !formats->formats) return selected;
 for(UINT32 i=0;i<formats->numFormats;i++) {
  const CLIPRDR_FORMAT *format=&formats->formats[i];
  if(format->formatId==RDP_CLIPBOARD_FORMAT_ID_FILE_GROUP_DESCRIPTOR ||
     (format->formatName && strcmp(format->formatName,
                                   RDP_CLIPBOARD_FORMAT_NAME_FILE_GROUP_DESCRIPTOR)==0)) {
   selected.kind=RDP_CLIPBOARD_KIND_FILES;
   selected.format_id=format->formatId;
   return selected;
  }
  if(text.format_id==0 &&
     (format->formatId==RDP_CLIPBOARD_FORMAT_ID_TEXT ||
      (format->formatName &&
       strcmp(format->formatName,RDP_CLIPBOARD_FORMAT_NAME_TEXT)==0))) {
   text.format_id=format->formatId;
  }
 }
 return text.format_id ? text : selected;
}

/* Callback for a client CB_FORMAT_DATA_REQUEST: the server serves its local
 * clipboard data (text or FileGroupDescriptorW) to the client. */
static inline void rdp_clipboard_set_callbacks(CliprdrServerContext *cliprdr,
                                               psCliprdrClientFormatDataRequest incoming) {
 cliprdr->ClientFormatDataRequest=incoming;
}

/* Callback for a client CB_FILECONTENTS_REQUEST: the server serves local file
 * bytes (FILECONTENTS_SIZE / FILECONTENTS_RANGE) to the client. */
static inline void rdp_clipboard_set_file_contents_callback(CliprdrServerContext *cliprdr,
                                                            psCliprdrClientFileContentsRequest incoming) {
 cliprdr->ClientFileContentsRequest=incoming;
}

/* Acknowledge a client CB_FORMAT_LIST with CB_RESPONSE_OK, then send the
 * CB_FORMAT_DATA_REQUEST for one selection the caller already made (so the
 * caller can store the semantic pending kind and log the advertised id before
 * the response arrives). Returns the send result of the request (CHANNEL_RC_OK
 * when there is nothing to request). */
static inline UINT rdp_clipboard_client_formats_selected(
    CliprdrServerContext *cliprdr,const CLIPRDR_FORMAT_LIST *formats,
    const rdp_clipboard_format_selection *selected) {
 if(!cliprdr || !formats || !cliprdr->ServerFormatListResponse) return CHANNEL_RC_OK;
 CLIPRDR_FORMAT_LIST_RESPONSE response={0};
 response.common.msgType=CB_FORMAT_LIST_RESPONSE;
 response.common.msgFlags=CB_RESPONSE_OK;
 UINT rc=cliprdr->ServerFormatListResponse(cliprdr,&response);
 if(rc!=CHANNEL_RC_OK) return rc;
 if(!selected || selected->kind==RDP_CLIPBOARD_KIND_NONE || selected->format_id==0 ||
    !cliprdr->ServerFormatDataRequest)
  return CHANNEL_RC_OK;
 CLIPRDR_FORMAT_DATA_REQUEST request={0};
 request.common.msgType=CB_FORMAT_DATA_REQUEST;
 request.requestedFormatId=selected->format_id;
 return cliprdr->ServerFormatDataRequest(cliprdr,&request);
}

/* Backwards-compatible wrapper used by the C unit harness: acknowledge the
 * client CB_FORMAT_LIST with CB_RESPONSE_OK, then request the selected format
 * with the id the client advertised (FileGroupDescriptorW for a file offer,
 * CF_UNICODETEXT for a text offer). Existing text clipboard behaviour is
 * preserved. */
static inline UINT rdp_clipboard_client_formats(CliprdrServerContext *cliprdr,
                                                const CLIPRDR_FORMAT_LIST *formats) {
 const rdp_clipboard_format_selection selected=rdp_clipboard_select_format(formats);
 return rdp_clipboard_client_formats_selected(cliprdr,formats,&selected);
}

#endif
