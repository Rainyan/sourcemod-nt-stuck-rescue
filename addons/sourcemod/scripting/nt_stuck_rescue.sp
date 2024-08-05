#include <sourcemod>
#include <sdktools>
#include <dhooks>

#include <neotokyo>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "0.1.0"

#define STEPSIZE_MULTIPLIER 2.5 // just a magic value that seemed to work fine
#define FALL_UPS 400.0 // TODO: can this be queried from anywhere?

float _stepsize;
float _prevVel[NEO_MAXPLAYERS+1];
bool _rescue[NEO_MAXPLAYERS+1];
bool _fakeground = false;
int _processclient;

public Plugin myinfo = {
	name = "NT Stuck Rescue",
	description = "If a player is stuck between 2 slopes, \
allow them to jump to un-stuck.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-stuck-rescue"
}

public void OnPluginStart()
{
	ConVar stepsize = FindConVar("sv_stepsize");
	if (!stepsize)
	{
		SetFailState("Couldn't find cvar");
	}
	_stepsize = stepsize.FloatValue * STEPSIZE_MULTIPLIER;
	stepsize.AddChangeHook(StepsizeChanged);

	DynamicHook dh = new DynamicHook(19, HookType_Raw, ReturnType_Int,
		ThisPointer_Address);
	if (!dh)
	{
		SetFailState("Failed to create dynamic hook");
	}
	Address gamemovement = view_as<Address>(0x22542898);
	if (INVALID_HOOK_ID == dh.HookRaw(Hook_Pre, gamemovement,
		CGameMovement__CheckJumpButton))
	{
		SetFailState("Failed to hook entity");
	}
	delete dh;

	DynamicDetour dd = new DynamicDetour(view_as<Address>(0x221F5020),
		CallConv_THISCALL, ReturnType_CBaseEntity, ThisPointer_CBaseEntity);
	if (!dd)
	{
		SetFailState("Failed to create detour");
	}
	if (!dd.Enable(Hook_Pre, CBaseEntity__GetGroundEntity))
	{
		SetFailState("Failed to detour");
	}
	delete dd;

	CreateTimer(GetTickInterval(), Timer_CheckStuck, _, TIMER_REPEAT);
}

public void OnClientDisconnect(int client)
{
	_prevVel[client] = 0.0;
	_rescue[client] = _fakeground = false;
}

void StepsizeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	_stepsize = StringToFloat(newValue) * STEPSIZE_MULTIPLIER;
}

MRESReturn CGameMovement__CheckJumpButton(Address pThis, DHookReturn hReturn)
{
	int client = GetBaseEntity(view_as<Address>(
		LoadFromAddress(pThis + view_as<Address>(8), NumberType_Int32)));

	if (_rescue[client])
	{
		_fakeground = true;
		return MRES_Handled;
	}
	return MRES_Ignored;
}

MRESReturn CBaseEntity__GetGroundEntity(int pThis, DHookReturn hReturn)
{
	bool fake = _fakeground;
	_fakeground = false;
	if (fake)
	{
		_rescue[pThis] = false;
		hReturn.Value = pThis;
		return MRES_Supercede;
	}
	return MRES_Ignored;
}

public Action Timer_CheckStuck(Handle timer)
{
	// Stagger because we don't need to check this that often for all the clients
	_processclient = 1 + (_processclient) % (MaxClients/2);
	if (IsClientInGame(_processclient))
	{
		ProcessClient(_processclient);
	}
	return Plugin_Continue;
}

void ProcessClient(int client)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}

	if (GetEntityFlags(client) & FL_ONGROUND)
	{
		return;
	}

	float absvel[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", absvel);

	// Not falling.
	if (absvel[2] >= 0)
	{
		_rescue[client] = false;
		return;
	}

	// Moving too fast to be considered stuck.
#define MAX_SPEED 32
	if (absvel[0]*absvel[0] > MAX_SPEED*MAX_SPEED ||
		absvel[1]*absvel[1] > MAX_SPEED*MAX_SPEED)
	{
		return;
	}

	// Already in rescue, no need to calculate anything more.
	if (_rescue[client])
	{
		return;
	}

	// Not the initial falling velocity.
	float fallPerTick = GetTickInterval() * FALL_UPS;
	if (!FloatApproxEq(-absvel[2], fallPerTick, fallPerTick*0.1))
	{
		return;
	}

	// Prev tick wasn't the inital falling velocity.
	if (_prevVel[client] != (_prevVel[client] = absvel[2]))
	{
		return;
	}

	// Using noclip or similar.
	if (GetEntityMoveType(client) != MOVETYPE_WALK)
	{
		return;
	}

	// We're not floating nearby a plausible surface.
	if (!UTIL_CheckBottom(client, _stepsize))
	{
		return;
	}

	_rescue[client] = true;
}

bool FloatApproxEq(float a, float b, float ulps)
{
	return FloatAbs(a-b) <= ulps;
}

int GetBaseEntity(Address self)
{
	static Handle call = INVALID_HANDLE;
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Raw);
		PrepSDKCall_SetVirtual(5);
		PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prep SDK call");
		}
	}
	return SDKCall(call, self);
}

bool UTIL_CheckBottom(int entity, float stepsize)
{
	static Handle call = INVALID_HANDLE;
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Static);
		char sig[] = "\x81\xEC\xCC\x00\x00\x00\x83\xBC\x24\xD4\x00\x00\x00\x00";
		PrepSDKCall_SetSignature(SDKLibrary_Server, sig, sizeof(sig)-1);
		PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
		PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prep SDK call");
		}
	}
	const int sizeof_CTraceFilterSimple = 12;
	Address alloc = MemAllocScratch(sizeof_CTraceFilterSimple);
	Address filter = CTraceFilterSimple(entity, 0, alloc);
	bool ret = SDKCall(call, entity, filter, stepsize);
	MemFreeScratch();
	return ret;
}

Address CTraceFilterSimple(int entity, int collisiongroup, Address create_to)
{
	static Handle call = INVALID_HANDLE;
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Raw);
		char sig[] = "\x8B\x54\x24\x08\x8B\xC1\x8B\x4C\x24\x04\xC7\x00\x2A\x2A\x2A\x2A\x89\x48\x04";
		PrepSDKCall_SetSignature(SDKLibrary_Server, sig, sizeof(sig)-1);
		PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prep SDK call");
		}
	}
	return SDKCall(call, create_to, entity, collisiongroup);
}

Address MemAllocScratch(int bytes)
{
	static Handle call = INVALID_HANDLE;
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Static);
		PrepSDKCall_SetAddress(view_as<Address>(0x2235FE7E));
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prep SDK call");
		}
	}
	return SDKCall(call, bytes);
}

void MemFreeScratch()
{
	static Handle call = INVALID_HANDLE;
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Static);
		PrepSDKCall_SetAddress(view_as<Address>(0x2235FE78));
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prep SDK call");
		}
	}
	SDKCall(call);
}