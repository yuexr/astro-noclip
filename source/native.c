#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "MinHook.h"

typedef struct { float x,y,z; } Vec;
typedef Vec *(*AdjustFn)(void *, Vec *, const unsigned char *, float, const Vec *);
static AdjustFn original;
static unsigned char *objects, *pool;
static HMODULE module;
static void *selected;
static int selected_index, selected_serial;
static int active;
typedef unsigned char (*MoveFn)(void *, const Vec *, float, unsigned char, void *, unsigned char);
static MoveFn original_move;
static LONG unswept;
typedef void (*FlightFn)(void *,float);
static FlightFn original_flight;
static LONG flight_calls,contacts_cleared;
static const unsigned char flight_signature[] = {
    0x48,0x8b,0xc4,0x48,0x89,0x58,0x18,0x48,0x89,0x78,0x20,0x55,
    0x48,0x8d,0xa8,0x68,0xff,0xff,0xff,0x48,0x81,0xec,0x90,0x01
};
static const unsigned char move_signature[] = {
    0x40,0x53,0x55,0x41,0x56,0x48,0x83,0xec,0x60,0xff,0x81,0xe0,0x03,0x00,0x00,
    0x48,0x8b,0xd9,0x48,0x8b,0x89,0xc8,0x00,0x00,0x00
};
static const unsigned char signature[] = {
    0x48,0x83,0xec,0x48,0x41,0xf6,0x40,0x5d,0x02,0x75,0x1d,
    0x8b,0x05,0x5f,0xca,0xa1,0x04,0xf2,0x0f,0x10,0x05,0x4f,0xca,0xa1,0x04
};

static void sibling(wchar_t *path, const wchar_t *name) {
    DWORD n=GetModuleFileNameW(module,path,32768);
    if(!n || n>32500) { path[0]=0; return; }
    while(n && path[n-1]!=L'\\' && path[n-1]!=L'/') --n;
    wcscpy(path+n,name);
}
static void status(const char *message) {
    wchar_t path[32768]; sibling(path,L"NoclipCollisionToggle-status.txt");
    FILE *f=_wfopen(path,L"w");
    if(f) { fprintf(f,"%s\n",message); fclose(f); }
}
static void *object_at(int index, int serial) {
    if(!objects || index<0) return NULL;
    int count; memcpy(&count,objects+36,4);
    if(index>=count) return NULL;
    unsigned char **chunks; memcpy(&chunks,objects+16,8);
    unsigned char *chunk=chunks[(unsigned)index/65536];
    if(!chunk) return NULL;
    unsigned char *item=chunk+((unsigned)index%65536)*24;
    int current; memcpy(&current,item+16,4);
    if(current!=serial) return NULL;
    void *object; memcpy(&object,item,8); return object;
}
static int class_is(void *object, const char *name) {
    unsigned char *cls; memcpy(&cls,(unsigned char *)object+16,8);
    if(!cls) return 0;
    uint32_t index; memcpy(&index,cls+24,4);
    if((index>>16)>=8192) return 0;
    unsigned char **blocks=(unsigned char **)(pool+16);
    unsigned char *block=blocks[index>>16];
    if(!block) return 0;
    unsigned char *entry=block+(index&65535)*2;
    uint16_t header; memcpy(&header,entry,2);
    size_t n=strlen(name);
    return !(header&1) && (header>>6)==n && !memcmp(entry+2,name,n);
}
static Vec *adjust(void *movement, Vec *out, const unsigned char *hit, float dt, const Vec *delta) {
    if(selected && movement==selected && object_at(selected_index,selected_serial)==selected && hit) {
        out->x=out->y=out->z=0;
        return out;
    }
    return original(movement,out,hit,dt,delta);
}
static unsigned char move(void *movement,const Vec *delta,float dt,unsigned char sweep,void *hit,unsigned char teleport) {
    if(selected && movement==selected && object_at(selected_index,selected_serial)==selected) {
        sweep=0;
        InterlockedIncrement(&unswept);
    }
    return original_move(movement,delta,dt,sweep,hit,teleport);
}
static void flight(void *movement,float dt) {
    if(selected && movement==selected && object_at(selected_index,selected_serial)==selected) {
        unsigned char *m=movement;
        Vec drift; memcpy(&drift,m+0x18c,sizeof(drift));
        if((m[0x148]&1) || drift.x!=0 || drift.y!=0 || drift.z!=0)
            InterlockedIncrement(&contacts_cleared);
        // Clear contact drift before normal flight.
        m[0x148]&=0xfe;
        memset(m+0x18c,0,sizeof(Vec));
        InterlockedIncrement(&flight_calls);
    }
    original_flight(movement,dt);
}
static int initialize(void) {
    unsigned char *game=(unsigned char *)GetModuleHandleW(L"Astro-Win64-Shipping.exe");
    if(!game) { status("INACTIVE: Astroneer is unavailable."); return 0; }
    IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER *)game;
    IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64 *)(game+dos->e_lfanew);
    if(nt->FileHeader.TimeDateStamp!=0x6ABB803D || nt->OptionalHeader.SizeOfImage!=0x6D07000 ||
       memcmp(game+0x1b44cc0,signature,sizeof(signature)) ||
       memcmp(game+0x1b4cb10,move_signature,sizeof(move_signature)) ||
       memcmp(game+0x1b3a480,flight_signature,sizeof(flight_signature))) {
        status("INACTIVE: Unsupported game build or movement signature."); return 0;
    }
    objects=game+0x65f8820; pool=game+0x65bc000;
    unsigned char *block=*(unsigned char **)(pool+16);
    if(!block || memcmp(block+2,"None",4)) {
        status("INACTIVE: Name-pool check failed."); return 0;
    }
    HMODULE pinned;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,(LPCWSTR)&adjust,&pinned)) {
        status("INACTIVE: Could not keep the helper loaded."); return 0;
    }
    if(MH_Initialize()!=MH_OK || MH_CreateHook(game+0x1b44cc0,(void *)&adjust,(void **)&original)!=MH_OK ||
       MH_CreateHook(game+0x1b4cb10,(void *)&move,(void **)&original_move)!=MH_OK ||
       MH_CreateHook(game+0x1b3a480,(void *)&flight,(void **)&original_flight)!=MH_OK ||
       MH_EnableHook(MH_ALL_HOOKS)!=MH_OK) {
        MH_DisableHook(MH_ALL_HOOKS);
        status("INACTIVE: Could not install the movement hook."); return 0;
    }
    active=1; status("ACTIVE: Noclip ready; defaults off."); return 1;
}
__declspec(dllexport) int luaopen_noclipcollisiontoggle(void *state) {
    (void)state; if(!active) initialize(); return 0;
}
__declspec(dllexport) int luaopen_noclipcollisiontoggle_refresh(void *state) {
    (void)state; selected=NULL;
    if(!active) { status("INACTIVE: Native hook is unavailable."); return 0; }
    wchar_t path[32768]; sibling(path,L"NoclipCollisionToggle-session.txt");
    FILE *f=_wfopen(path,L"r"); unsigned long long address=0;
    if(f) { if(fscanf(f,"%llx",&address)!=1) address=0; fclose(f); }
    if(!address) { status("ACTIVE: Noclip off."); return 0; }
    // Check the object array before using this address.
    unsigned char **chunks=*(unsigned char ***)(objects+16);
    int count; memcpy(&count,objects+36,4);
    for(int i=0;i<count;++i) {
        unsigned char *item=chunks[(unsigned)i/65536]+((unsigned)i%65536)*24;
        void *object; memcpy(&object,item,8);
        if((uintptr_t)object!=(uintptr_t)address) continue;
        if(!class_is(object,"AstroCharacterMovementComponent")) break;
        selected_index=i; memcpy(&selected_serial,item+16,4);
        unswept=0; flight_calls=0; contacts_cleared=0; selected=object;
        status("ACTIVE: Noclip on."); return 0;
    }
    status("INACTIVE: Requested movement component was not found."); return 0;
}
__declspec(dllexport) int luaopen_noclipcollisiontoggle_inspect(void *state) {
    (void)state; char message[160];
    snprintf(message,sizeof(message),"ACTIVE: Noclip %s; flight_calls=%ld contact_drifts_cleared=%ld moves_unswept=%ld",selected ? "on" : "off",(long)flight_calls,(long)contacts_cleared,(long)unswept);
    status(message); return 0;
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved) {
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH) {module=instance;DisableThreadLibraryCalls(instance);}
    return TRUE;
}
