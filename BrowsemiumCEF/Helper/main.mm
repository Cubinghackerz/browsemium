#import "BrowsemiumCEF.h"

/// Entry point for every Chromium helper process (renderer, GPU, utility).
/// The same binary is copied into each helper bundle; CEF decides what role it
/// plays from the command line the browser process passes it.
int main(int argc, char* argv[]) {
  return BrowsemiumCEFHelperMain(argc, argv);
}
