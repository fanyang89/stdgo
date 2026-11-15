pub const multipart = @import("mime/multipart.zig");
pub const mediatype = @import("mime/mediatype.zig");
pub const quotedprintable = @import("mime/quotedprintable.zig");

pub const parseMediaType = mediatype.parseMediaType;
pub const formatMediaType = mediatype.formatMediaType;
pub const typeByExtension = mediatype.typeByExtension;
pub const extensionsByType = mediatype.extensionsByType;
pub const MediaType = mediatype.MediaType;

test {
    @import("std").testing.refAllDecls(@This());
    _ = multipart;
    _ = mediatype;
    _ = quotedprintable;
}
