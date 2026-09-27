#include "LegacyBundleLayout.h"
#include "MachOImage.h"
#include "../include/LC32LegacyBundleLayout.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool ReadAt(int fd, void *buffer, size_t size, uint64_t offset) {
    if(offset > INT64_MAX || size > (uint64_t)INT64_MAX - offset) return false;
    size_t done = 0;
    while(done < size) {
        ssize_t count = pread(fd, (char *)buffer + done, size - done,
            (off_t)(offset + done));
        if(count < 0 && errno == EINTR) continue;
        if(count <= 0) return false;
        done += (size_t)count;
    }
    return true;
}

static bool ContainsShimMarker(int fd, const LC32MachOSlice *slice) {
    /* App/main.c keeps this section while the injector changes load-command
     * SDK values and re-signs. Do not classify an arbitrary universal app as
     * injected just because it has an ARM64 slice or imports our framework. */
    static const char marker[] = "LiveExec32InjectedShim:1";
    uint64_t offset = slice->headerSize;
    const uint64_t end = offset + slice->loadCommandBytes;
    bool found = false;
    for(uint32_t i = 0; i < slice->loadCommandCount; ++i) {
        struct load_command command;
        if(offset > end || sizeof(command) > end - offset ||
                !ReadAt(fd, &command, sizeof(command), slice->offset + offset) ||
                command.cmdsize < sizeof(command) ||
                command.cmdsize > end - offset) return false;
        if(command.cmd == LC_SEGMENT_64) {
            struct segment_command_64 segment;
            if(command.cmdsize < sizeof(segment) ||
                    !ReadAt(fd, &segment, sizeof(segment), slice->offset + offset) ||
                    segment.nsects > (command.cmdsize - sizeof(segment)) /
                        sizeof(struct section_64)) return false;
            for(uint32_t s = 0; s < segment.nsects; ++s) {
                struct section_64 section;
                if(!ReadAt(fd, &section, sizeof(section), slice->offset + offset +
                        sizeof(segment) + s * sizeof(section))) return false;
                if(strncmp(segment.segname, SEG_TEXT, sizeof(segment.segname)) ||
                        strncmp(section.segname, SEG_TEXT, sizeof(section.segname)) ||
                        strncmp(section.sectname, "__lc32shim", sizeof(section.sectname))) {
                    continue;
                }
                char bytes[sizeof(marker)];
                if(found || section.size != sizeof(marker) ||
                        (section.flags & SECTION_TYPE) != S_REGULAR ||
                        section.offset < segment.fileoff ||
                        section.offset - segment.fileoff > segment.filesize ||
                        section.size > segment.filesize -
                            (section.offset - segment.fileoff) ||
                        section.offset > slice->size ||
                        section.size > slice->size - section.offset ||
                        !ReadAt(fd, bytes, sizeof(bytes), slice->offset + section.offset) ||
                        memcmp(bytes, marker, sizeof(marker))) return false;
                found = true;
            }
        }
        offset += command.cmdsize;
    }
    return found && offset == end;
}

bool LC32ExecutableNeedsLegacyBundleLayout(int fd) {
    LC32MachOImage image = {0};
    if(!LC32MachOImageParseFD(fd, &image, NULL, 0) || !image.isFat) return false;
    bool guestFound = false;
    bool shimFound = false;
    for(uint32_t i = 0; i < image.count; ++i) {
        const LC32MachOSlice *slice = &image.slices[i];
        if(slice->isByteSwapped || slice->fileType != MH_EXECUTE) return false;
        if(slice->cpuType == CPU_TYPE_ARM) {
            if((slice->hasVersionMinIPhoneOS &&
                    slice->versionMinIPhoneOSSDK >= (8u << 16)) ||
                    (slice->hasBuildVersion && (slice->buildVersionPlatform != PLATFORM_IOS ||
                    slice->buildVersionSDK >= (8u << 16)))) return false;
            guestFound = true;
        } else if(slice->cpuType == CPU_TYPE_ARM64 && !shimFound && i == 0 &&
                ((uint32_t)slice->cpuSubtype & ~(uint32_t)CPU_SUBTYPE_MASK) ==
                    CPU_SUBTYPE_ARM64_ALL &&
                slice->hasBuildVersion && slice->buildVersionPlatform == PLATFORM_IOS &&
                ContainsShimMarker(fd, slice)) {
            shimFound = true;
        } else {
            return false;
        }
    }
    return guestFound && shimFound;
}

static int CheckOuterLink(int homeFD) {
    struct stat metadata;
    if(fstatat(homeFD, LC32_LEGACY_BUNDLE_ALIAS_NAME, &metadata,
            AT_SYMLINK_NOFOLLOW) != 0) return errno;
    if(!S_ISLNK(metadata.st_mode)) return EEXIST;
    char target[sizeof(LC32_LEGACY_BUNDLE_MANAGED_TARGET)];
    ssize_t length = readlinkat(homeFD, LC32_LEGACY_BUNDLE_ALIAS_NAME,
        target, sizeof(target));
    if(length < 0) return errno;
    return length == sizeof(LC32_LEGACY_BUNDLE_MANAGED_TARGET) - 1 &&
        memcmp(target, LC32_LEGACY_BUNDLE_MANAGED_TARGET, (size_t)length) == 0 ?
            0 : EEXIST;
}

int LC32CreateLegacyBundleOuterLink(const char *homePath) {
    if(homePath == NULL || homePath[0] != '/' || homePath[1] == '\0') return EINVAL;
    size_t length = strnlen(homePath, PATH_MAX);
    if(length == PATH_MAX) return ENAMETOOLONG;
    char home[PATH_MAX];
    memcpy(home, homePath, length + 1);
    /* A trailing slash would make O_NOFOLLOW apply after following a final
     * symlink. Strip it, and reject dot components rather than treating an
     * app-controlled spelling as a different final container component. */
    while(length > 1 && home[length - 1] == '/') home[--length] = '\0';
    for(const char *part = home + 1; *part;) {
        const char *end = strchr(part, '/');
        size_t size = end != NULL ? (size_t)(end - part) : strlen(part);
        if((size == 1 && part[0] == '.') ||
                (size == 2 && part[0] == '.' && part[1] == '.')) return EINVAL;
        if(end == NULL) break;
        part = end + 1;
    }
    char resolved[PATH_MAX];
    if(realpath(home, resolved) == NULL) return errno;
    if(resolved[1] == '\0') return EINVAL;
    const int homeFD = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if(homeFD < 0) return errno;
    const int documentsFD = openat(homeFD, "Documents",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    int result = documentsFD < 0 ? errno : CheckOuterLink(homeFD);
    if(documentsFD >= 0 && result == ENOENT) {
        /* Publishing the convention grants bootstrap ownership of the inner
         * symlink. Do not claim a pre-existing Documents entry on first use. */
        struct stat inner;
        if(fstatat(documentsFD, LC32_LEGACY_BUNDLE_INNER_ALIAS_NAME, &inner,
                AT_SYMLINK_NOFOLLOW) == 0) {
            result = EEXIST;
        } else if(errno != ENOENT) {
            result = errno;
        } else if(symlinkat(LC32_LEGACY_BUNDLE_MANAGED_TARGET, homeFD,
                LC32_LEGACY_BUNDLE_ALIAS_NAME) == 0) {
            result = 0;
        } else {
            result = errno == EEXIST ? CheckOuterLink(homeFD) : errno;
        }
    }
    if(documentsFD >= 0) close(documentsFD);
    close(homeFD);
    return result;
}
