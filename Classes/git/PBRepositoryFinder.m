//
//  PBRepositoryFinder.m
//  GitX
//
//  Created by Rowan James on 13/11/2012.
//
//

#import "PBRepositoryFinder.h"

@implementation PBRepositoryFinder

+ (NSURL *)workDirForURL:(NSURL *)fileURL;
{
	NSString *path = fileURL.path;
	if (!fileURL.isFileURL || path.length == 0) {
		return nil;
	}

	git_repository *repo = NULL;
	int gitResult = git_repository_open_ext(&repo,
											path.UTF8String,
											GIT_REPOSITORY_OPEN_CROSS_FS,
											NULL);
	if (gitResult != GIT_OK || !repo) {
		return nil;
	}

	const char *workdir = git_repository_workdir(repo);
	NSURL *result = nil;
	if (workdir) {
		result = [NSURL fileURLWithPath:[NSString stringWithUTF8String:workdir]];
	}

	git_repository_free(repo);
	repo = nil;
	return result;
}

+ (NSURL *)gitDirForURL:(NSURL *)fileURL
{
	NSString *path = fileURL.path;
	if (!fileURL.isFileURL || path.length == 0) {
		return nil;
	}
	git_buf path_buffer = {NULL, 0, 0};
	int gitResult = git_repository_discover(&path_buffer,
											path.UTF8String,
											GIT_REPOSITORY_OPEN_CROSS_FS,
											nil);

	NSData *repoPathBuffer = nil;
	if (path_buffer.ptr) {
		repoPathBuffer = [NSData dataWithBytes:path_buffer.ptr length:path_buffer.asize];
		git_buf_free(&path_buffer);
	}

	if (gitResult == GIT_OK && repoPathBuffer.length) {
		NSString *repoPath = [NSString stringWithUTF8String:repoPathBuffer.bytes];
		BOOL isDirectory;
		if ([[NSFileManager defaultManager] fileExistsAtPath:repoPath
												 isDirectory:&isDirectory] &&
			isDirectory) {
			NSURL *result = [NSURL fileURLWithPath:repoPath
									   isDirectory:isDirectory];
			return result;
		}
	}
	return nil;
}

+ (NSURL *)fileURLForURL:(NSURL *)inputURL
{
	NSString *path = inputURL.path;
	if (!inputURL.isFileURL || path.length == 0) {
		return nil;
	}

	git_repository *repo = NULL;
	int gitResult = git_repository_open_ext(&repo,
											path.UTF8String,
											GIT_REPOSITORY_OPEN_CROSS_FS,
											NULL);
	if (gitResult != GIT_OK || !repo) {
		return nil;
	}

	const char *repositoryPath = git_repository_workdir(repo);
	if (!repositoryPath) {
		repositoryPath = git_repository_path(repo); // bare repository
	}
	NSURL *result = repositoryPath ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:repositoryPath]] : nil;

	git_repository_free(repo);
	return result;
}

@end
