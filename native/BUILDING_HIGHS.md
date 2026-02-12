# Building HiGHS with Zig

No cmake. No Python. Just Zig compiling the HiGHS C/C++ source directly.

## 1. Clone HiGHS

```bash
git clone --depth 1 https://github.com/ERGO-Code/HiGHS.git
cd HiGHS
```

## 2. Create the config header

HiGHS needs a generated `HConfig.h`. Create it manually:

```bash
cat > HConfig.h << 'EOF'
#ifndef HCONFIG_H_
#define HCONFIG_H_

#define CUPDLP_CPU
#define HIGHS_HAVE_BUILTIN_CLZ

#define HIGHS_GITHASH "zig-build"
#define HIGHS_VERSION_MAJOR 1
#define HIGHS_VERSION_MINOR 13
#define HIGHS_VERSION_PATCH 1

#endif
EOF
```

## 3. Build static library with Zig

```bash
mkdir -p build

# Include paths
INC="-I. \
  -I./highs -I./highs/interfaces -I./highs/io -I./highs/io/filereader \
  -I./highs/ipm -I./highs/ipm/ipx -I./highs/ipm/basiclu \
  -I./highs/lp_data -I./highs/mip -I./highs/model -I./highs/parallel \
  -I./highs/pdlp -I./highs/pdlp/cupdlp -I./highs/presolve \
  -I./highs/qpsolver -I./highs/simplex -I./highs/test_kkt -I./highs/util \
  -I./extern -I./extern/pdqsort -I./extern/zstr"

FLAGS="-O2 -DNDEBUG -DCUPDLP_CPU"

# Compile all C++ source files (.cpp)
for f in $(find highs -name "*.cpp" -not -path "*/hipo/*"); do
  echo "C++ $f"
  zig c++ -std=c++17 $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"
done

# Compile all IPX files (.cc)
for f in $(find highs/ipm/ipx -name "*.cc"); do
  echo "CC  $f"
  zig c++ -std=c++17 $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"
done

# Compile C files (basiclu + cupdlp)
for f in $(find highs/ipm/basiclu -name "*.c") \
         $(find highs/pdlp/cupdlp -name "*.c" -not -path "*/cuda/*"); do
  echo "C   $f"
  zig cc $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"
done

# Create static library
ar rcs build/libhighs.a build/*.o
echo ""
echo "Built: build/libhighs.a ($(ls build/*.o | wc -l) object files)"
```

## 4. Install

```bash
sudo cp build/libhighs.a /usr/local/lib/
sudo cp highs/interfaces/highs_c_api.h /usr/local/include/
sudo cp highs/lp_data/HighsCallbackStruct.h /usr/local/include/
```

## 5. Build the solver (static linked, no dlopen)

Once you have `libhighs.a`, the solver no longer needs `dlopen`.
Replace the solver with a statically linked version:

```bash
cd ammonia_desk/native

zig build-exe solver.zig \
  -lhighs -lstdc++ \
  -L/usr/local/lib \
  -lc
```

This produces a **single self-contained binary**. No `.so` files,
no `dlopen`, no library path issues. Copy it anywhere and it runs.

## 6. Verify

```bash
./native/solver
# Should print: solver: ready, waiting for commands...
```

## Cross-compile (optional)

Build for Linux ARM64 from any machine:

```bash
# In step 3, add target flag:
zig c++ -std=c++17 -target aarch64-linux-gnu $FLAGS $INC -c "$f" -o "build/..."
zig cc -target aarch64-linux-gnu $FLAGS $INC -c "$f" -o "build/..."

# In step 5:
zig build-exe solver.zig -target aarch64-linux-gnu -lhighs -lstdc++ -L./build -lc
```

## Troubleshooting

**"undefined reference to ..."** during step 5:
You're missing object files. Check that all `.cpp`, `.cc`, and `.c`
files compiled without errors in step 3.

**"HConfig.h not found"**:
Make sure `HConfig.h` is in the HiGHS root directory (same level as
the `highs/` folder).

**macOS: "library not found for -lstdc++"**:
Use `-lc++` instead of `-lstdc++` on macOS.
