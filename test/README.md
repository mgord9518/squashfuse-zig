# Simple SquashFS images for testing

To test squashfuse-zig functionality, first run `make_images.sh`, which will
generate test SquashFS images for different compression algos.

After, `zig build test` will ensure everything is working as intended
