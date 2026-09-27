#include "../LegacyBundleLayout.h"
#include "../../include/LC32LegacyBundleLayout.h"

#include <errno.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks;
static unsigned failures;
#define CHECK(condition) do { ++checks; if(!(condition)) { \
    ++failures; fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
} } while(0)

static unsigned char image[0x3000];

static void MakeExecutable(uint32_t sdk) {
    memset(image, 0, sizeof(image));
    struct fat_header fat = {OSSwapHostToBigInt32(FAT_MAGIC), OSSwapHostToBigInt32(2)};
    struct fat_arch arch[2] = {
        {OSSwapHostToBigInt32(CPU_TYPE_ARM64), OSSwapHostToBigInt32(CPU_SUBTYPE_ARM64_ALL),
         OSSwapHostToBigInt32(0x1000), OSSwapHostToBigInt32(0x1000), OSSwapHostToBigInt32(12)},
        {OSSwapHostToBigInt32(CPU_TYPE_ARM), OSSwapHostToBigInt32(CPU_SUBTYPE_ARM_V7),
         OSSwapHostToBigInt32(0x2000), OSSwapHostToBigInt32(0x1000), OSSwapHostToBigInt32(12)}
    };
    memcpy(image, &fat, sizeof(fat));
    memcpy(image + sizeof(fat), arch, sizeof(arch));
    struct mach_header_64 shim = {
        .magic = MH_MAGIC_64, .cputype = CPU_TYPE_ARM64,
        .cpusubtype = CPU_SUBTYPE_ARM64_ALL, .filetype = MH_EXECUTE,
        .ncmds = 2, .sizeofcmds = sizeof(struct segment_command_64) +
            sizeof(struct section_64) + sizeof(struct build_version_command)
    };
    struct segment_command_64 segment = {
        .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(segment) + sizeof(struct section_64),
        .segname = SEG_TEXT, .vmaddr = 0x100000000,
        .vmsize = 0x1000, .filesize = 0x1000, .nsects = 1
    };
    struct section_64 section = {
        .sectname = "__lc32shim", .segname = SEG_TEXT,
        .addr = 0x100000400, .offset = 0x400,
        .size = sizeof("LiveExec32InjectedShim:1"), .flags = S_REGULAR
    };
    struct build_version_command build = {
        .cmd = LC_BUILD_VERSION, .cmdsize = sizeof(build),
        .platform = PLATFORM_IOS, .minos = 11u << 16, .sdk = 11u << 16
    };
    memcpy(image + 0x1000, &shim, sizeof(shim));
    memcpy(image + 0x1000 + sizeof(shim), &segment, sizeof(segment));
    memcpy(image + 0x1000 + sizeof(shim) + sizeof(segment), &section, sizeof(section));
    memcpy(image + 0x1000 + sizeof(shim) + sizeof(segment) + sizeof(section), &build, sizeof(build));
    memcpy(image + 0x1400, "LiveExec32InjectedShim:1", section.size);
    struct mach_header guest = {
        .magic = MH_MAGIC, .cputype = CPU_TYPE_ARM,
        .cpusubtype = CPU_SUBTYPE_ARM_V7, .filetype = MH_EXECUTE,
        .ncmds = 1, .sizeofcmds = sizeof(struct version_min_command)
    };
    struct version_min_command version = {
        .cmd = LC_VERSION_MIN_IPHONEOS, .cmdsize = sizeof(version),
        .version = 4u << 16, .sdk = sdk
    };
    memcpy(image + 0x2000, &guest, sizeof(guest));
    memcpy(image + 0x2000 + sizeof(guest), &version, sizeof(version));
}

static bool Probe(int fd) {
    CHECK(pwrite(fd, image, sizeof(image), 0) == sizeof(image));
    return LC32ExecutableNeedsLegacyBundleLayout(fd);
}

int main(void) {
    alarm(30);
    char temporary[] = "/private/tmp/lc32-legacy-layout.XXXXXX";
    char *home = mkdtemp(temporary);
    if(home == NULL) return 1;
    int directory = open(home, O_RDONLY | O_DIRECTORY);
    if(directory < 0) return 1;
    int fd = openat(directory, "image", O_RDWR | O_CREAT | O_EXCL, 0600);
    if(fd < 0) return 1;
    MakeExecutable(6u << 16);
    CHECK(Probe(fd));
    MakeExecutable(0);
    CHECK(Probe(fd));
    MakeExecutable(8u << 16);
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    image[0x1400] = 'X';
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    struct section_64 *section = (void *)(image + 0x1000 +
        sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    section->size++;
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    section->offset = 0x4000;
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    section->flags = S_ZEROFILL;
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    struct mach_header *guest = (void *)(image + 0x2000);
    guest->filetype = MH_DYLIB;
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    struct fat_arch *arch = (void *)(image + sizeof(struct fat_header));
    struct fat_arch first = arch[0];
    arch[0] = arch[1];
    arch[1] = first;
    CHECK(!Probe(fd));
    MakeExecutable(7u << 16);
    guest->sizeofcmds = sizeof(struct uuid_command);
    struct uuid_command uuid = {.cmd = LC_UUID, .cmdsize = sizeof(uuid)};
    memcpy(image + 0x2000 + sizeof(*guest), &uuid, sizeof(uuid));
    CHECK(Probe(fd)); /* no SDK load command is legacy */
    CHECK(ftruncate(fd, 8) == 0);
    CHECK(!LC32ExecutableNeedsLegacyBundleLayout(fd));
    close(fd);
    CHECK(unlinkat(directory, "image", 0) == 0);

    CHECK(LC32CreateLegacyBundleOuterLink(home) == ENOENT);
    CHECK(mkdirat(directory, "Documents", 0700) == 0);
    int documents = openat(directory, "Documents", O_RDONLY | O_DIRECTORY);
    CHECK(documents >= 0);
    fd = openat(documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, O_CREAT | O_EXCL | O_WRONLY, 0600);
    CHECK(fd >= 0);
    if(fd >= 0) close(fd);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == EEXIST);
    CHECK(unlinkat(documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, 0) == 0);
    CHECK(mkdirat(documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, 0700) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == EEXIST);
    CHECK(unlinkat(documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, AT_REMOVEDIR) == 0);
    CHECK(symlinkat("unrelated", documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == EEXIST);
    CHECK(unlinkat(documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, 0) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == 0);
    CHECK(symlinkat("previous-bundle", documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == 0); /* existing convention is managed */
    CHECK(unlinkat(documents, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, 0) == 0);
    close(documents);
    char target[128];
    ssize_t length = readlinkat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, target, sizeof(target));
    CHECK(length == sizeof(LC32_LEGACY_BUNDLE_MANAGED_TARGET) - 1);
    CHECK(length > 0 && memcmp(target, LC32_LEGACY_BUNDLE_MANAGED_TARGET, (size_t)length) == 0);
    struct stat before, after;
    CHECK(fstatat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, &before, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == 0);
    CHECK(fstatat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, &after, AT_SYMLINK_NOFOLLOW) == 0);
    CHECK(before.st_ino == after.st_ino);
    CHECK(unlinkat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, 0) == 0);
    CHECK(symlinkat("unrelated", directory, LC32_LEGACY_BUNDLE_ALIAS_NAME) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == EEXIST);
    CHECK(readlinkat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, target, sizeof(target)) == 9);
    CHECK(memcmp(target, "unrelated", 9) == 0);
    CHECK(unlinkat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, 0) == 0);
    fd = openat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, O_CREAT | O_EXCL | O_WRONLY, 0600);
    CHECK(fd >= 0);
    if(fd >= 0) close(fd);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == EEXIST);
    CHECK(unlinkat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, 0) == 0);
    CHECK(mkdirat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, 0700) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) == EEXIST);
    CHECK(unlinkat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, AT_REMOVEDIR) == 0);
    CHECK(unlinkat(directory, "Documents", AT_REMOVEDIR) == 0);
    CHECK(symlinkat("/private/tmp", directory, "Documents") == 0);
    CHECK(LC32CreateLegacyBundleOuterLink(home) != 0);
    CHECK(fstatat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, &after, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT);
    CHECK(unlinkat(directory, "Documents", 0) == 0);
    CHECK(mkdirat(directory, "Documents", 0700) == 0);
    CHECK(symlinkat(home, directory, "home-alias") == 0);
    char aliasPath[1024];
    snprintf(aliasPath, sizeof(aliasPath), "%s/home-alias/", home);
    CHECK(LC32CreateLegacyBundleOuterLink(aliasPath) != 0);
    CHECK(fstatat(directory, LC32_LEGACY_BUNDLE_ALIAS_NAME, &after, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT);
    CHECK(unlinkat(directory, "home-alias", 0) == 0);
    CHECK(unlinkat(directory, "Documents", AT_REMOVEDIR) == 0);
    CHECK(LC32CreateLegacyBundleOuterLink("/") == EINVAL);
    CHECK(LC32CreateLegacyBundleOuterLink("/private/tmp/../..") == EINVAL);
    CHECK(LC32CreateLegacyBundleOuterLink("relative") == EINVAL);
    close(directory);
    CHECK(rmdir(home) == 0);
    printf("LegacyBundleLayoutTests: %u/%u checks passed\n", checks - failures, checks);
    return failures != 0;
}
