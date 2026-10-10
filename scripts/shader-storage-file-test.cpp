// Actual shader-storage open helper; no Vulkan, native window or game.
#include "shader_storage_file.h"
#include <array>
#include <cstdio>
using rex::graphics::vulkan::OpenShaderStorageFile;
int main(int argc,char** argv) {
  if(argc!=2)return 2;
  const std::filesystem::path path(argv[1]);
  const std::array<unsigned,2> initial={0x53504558,0x12345678};
  FILE* seed=rex::filesystem::OpenFile(path,"wb");if(!seed)return 2;
  if(fwrite(initial.data(),sizeof(initial),1,seed)!=1)return 2;fclose(seed);
  FILE* first=OpenShaderStorageFile(path);if(!first)return 2;
  std::array<unsigned,2> actual{};
  if(fread(actual.data(),sizeof(actual),1,first)!=1 || actual!=initial) {
    std::puts("FAIL: existing shader-cache header/record not loaded on reopen");fclose(first);return 1;
  }
  // Writes must still append after a header read, never overwrite old records.
  rex::filesystem::Seek(first,0,SEEK_SET);
  const unsigned next=0xabcdef01;if(fwrite(&next,sizeof(next),1,first)!=1)return 2;
  fclose(first);
  FILE* second=OpenShaderStorageFile(path);if(!second)return 2;
  std::array<unsigned,3> all{};
  if(fread(all.data(),sizeof(all),1,second)!=1 || all[0]!=initial[0] ||
      all[1]!=initial[1] || all[2]!=next) {
    std::puts("FAIL: second launch lost previous records or append semantics");return 1;
  }
  fclose(second);
  if(OpenShaderStorageFile(path/"missing")) {std::puts("FAIL: invalid path unexpectedly opened");return 1;}
  std::puts("PASS: existing header read, append preserves entries, second launch reloads all records, invalid path rejected");
}
