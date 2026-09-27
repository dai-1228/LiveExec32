#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>
#include <pthread.h>

static unsigned exerciseClassClusters(unsigned batches, unsigned worker) {
    unsigned failures = 0;
    const char *text = "A heap-backed string longer than the tagged-pointer "
        "limit exercises native class-cluster teardown and guest reuse.";
    for(unsigned batch = 0; batch < batches; ++batch) {
        NSAutoreleasePool *pool = [NSAutoreleasePool new];
        for(unsigned iteration = 0; iteration < 128; ++iteration) {
            NSString *string = [[NSString alloc] initWithBytes:text
                length:strlen(text) encoding:NSUTF8StringEncoding];
            if(!string || strcmp([string UTF8String], text) != 0) {
                ++failures;
                if(failures < 10) fprintf(stderr,
                    "class-cluster-reuse: invalid string, worker %u, "
                    "batch %u, item %u\n", worker, batch, iteration);
            }
            [string release];
            NSData *data = [[NSData alloc] initWithBytes:text
                length:strlen(text)];
            if(!data || [data length] != strlen(text) ||
                    memcmp([data bytes], text, strlen(text)) != 0) {
                ++failures;
                if(failures < 10) fprintf(stderr,
                    "class-cluster-reuse: invalid data, worker %u, "
                    "batch %u, item %u\n", worker, batch, iteration);
            }
            [data release];

            NSURL *url = [[NSURL alloc]
                initFileURLWithPath:@"/tmp/lc32-class-cluster-reuse"];
            if(!url || ![url isFileURL] ||
                    ![[url path] isEqualToString:
                        @"/tmp/lc32-class-cluster-reuse"]) {
                ++failures;
                if(failures < 10) fprintf(stderr,
                    "class-cluster-reuse: invalid URL, worker %u, "
                    "batch %u, item %u\n", worker, batch, iteration);
            }
            [url release];
        }
        [pool drain];
    }
    return failures;
}

typedef struct {
    unsigned worker;
    unsigned failures;
} Worker;

static void *runWorker(void *context) {
    Worker *worker = context;
    worker->failures = exerciseClassClusters(4, worker->worker);
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    unsigned failures = exerciseClassClusters(16, 0);
    printf("class-cluster-reuse-serial: %s (%u failed initializers)\n",
        failures ? "FAIL" : "PASS", failures);

    /* Final native releases can run guest -dealloc on one thread while a
     * second guest thread obtains the same just-freed ARM32 allocation. */
    pthread_t threads[4];
    Worker workers[4] = {};
    unsigned started = 0;
    for(; started < 4; ++started) {
        workers[started].worker = started + 1;
        const int error = pthread_create(
            &threads[started], NULL, runWorker, &workers[started]);
        if(error) {
            fprintf(stderr, "class-cluster-reuse: pthread_create failed: %d\n",
                error);
            ++failures;
            break;
        }
    }
    unsigned concurrentFailures = 0;
    for(unsigned index = 0; index < started; ++index) {
        if(pthread_join(threads[index], NULL) != 0) ++concurrentFailures;
        concurrentFailures += workers[index].failures;
    }
    printf("class-cluster-reuse-concurrent: %s (%u failures)\n",
        concurrentFailures || started != 4 ? "FAIL" : "PASS",
        concurrentFailures);
    return failures || concurrentFailures ? 1 : 0;
}
