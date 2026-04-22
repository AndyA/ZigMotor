fn useTestMicrozig() bool {
    if (@import("builtin").is_test)
        return true;
    const root = @import("root");
    if (@hasDecl(root, "USE_TEST_MICROZIG") and root.USE_TEST_MICROZIG)
        return true;
    return false;
}

pub const microzig = if (useTestMicrozig())
    @import("../testing/microzig.zig")
else
    @import("microzig");
