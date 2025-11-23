#!/usr/bin/env lua
--[====================================================================[

  Provisions a qemu virtual machine as isolated build environment.

  HINT: Run this script in an EMPTY DIRECTORY, as it will use the curent
        workking dir to put files there.

  Make sure the base image you're using has sshd running. The script
  will connect several times there via ssh cmdline for provisioning it.

  ]====================================================================]

do

	local qemuBaseQcow2Image = (arg[1] or nil)
	local sshPortExposed = 2229
	local sshUser = "user"
	local sshSudo = "sudo"
	local sshWorkdir = "./work"
	local sshConnectHost = (arg[2] or "127.0.0.1")
	local log = io.stderr

	function getBaseImg() return(assert(qemuBaseQcow2Image, "qemuBaseQcow2Image missing")) end

	function getSshWorkdir() return(assert(sshWorkdir, "sshWorkdir missing")) end

	function getSshPort() return(assert(sshPortExposed, "sshPortExposed missing")) end

	function getSshHost() return(assert(sshConnectHost, "sshConnectHost missing")) end

	function getSshUser() return(assert(sshUser, "sshUser missing")) end

	function getSshSudo() return(sshSudo or "") end

	getHostCachedir = (function() local val
		return function()
			if not val then
				local src = io.popen("printf %s ".. shEsc(os.getenv("PWD")) .."|md5sum -b -", "r")
				val = src:read(32)
				assert(val and val:len() == 32)
				val = "/var/tmp/".. val
				log:write("Using host cachedir: ".. val .."\n")
				os.execute("mkdir ".. shEsc(val))
			end
			return val
		end
	end)()

	function getVersionFile() return getHostCachedir() .. "/gitversion" end

	function getRunFile() return getHostCachedir() .."/run" end

	function getHdaFile() return getHostCachedir() .."/hda.qcow2" end

end


function shEsc( str )
	return "'".. str:gsub([[']], [['"'"']]) .."'"
end


function fileExists( path )
	local f = io.open(path, "rb")
	if f then f:close() end
	return not not f
end


function asSshCmd( cmd )
	return "ssh ".. getSshHost() .." -p".. getSshPort()
		.." -oUser=".. getSshUser()
		.." -T ".. shEsc("cd ".. getSshWorkdir() .." && ".. cmd) ..""
end


function asSshTtyCmd( cmd )
	return "ssh ".. getSshHost() .." -p".. getSshPort()
		.." -oUser=".. getSshUser()
		.." -t ".. shEsc("cd ".. getSshWorkdir() .." && ".. cmd) ..""
end


function getVersionApprox()
	local ok, a, b = os.execute("git describe > ".. getVersionFile() .."")
	if not ok then error(a..", "..b) end
	local f = io.open(getVersionFile(), "rb")
	local v = f:read("l")
	f:close()
	if v:find("^v[0-9]") then  v = v:sub(2)  end
	return v
end


function createVmDisk()
	if fileExists(getHdaFile()) then return end
	local ok, a, b = os.execute("qemu-img create -F qcow2 -f qcow2"
		.." -b ".. getBaseImg() .." ".. shEsc(getHdaFile()))
	if not ok then error(a..", "..b) end
end


function createVmRunScript()
	local f = io.open(getRunFile(), "wb")
	f:write("#!/bin/sh\n"
		.."set -e \\\n"
		.." && qemu-system-x86_64 \\\n"
		.."     -accel kvm -m size=2G -smp cores=\"${NPROC:-$(nproc)}\" \\\n"
		.."     -hda ".. getHdaFile() .." \\\n"
		.."     -display none \\\n"
		.."     -netdev user,id=n0,ipv6=off"
		..        ",hostfwd=tcp:127.0.0.1:".. getSshPort() .."-:22 \\\n"
		.."     -device e1000,netdev=n0 \\\n"
		.." && true \\\n"
		.."\n")
	f:close()
	local ok, a, b = os.execute("chmod +x ".. shEsc(getRunFile()))
	if not ok then
		log:warn("[WARN ] chmod: ".. a .." ".. b .."\n")
	end
end


function sleepSec( sec )
	assert(type(sec) == "number")
	local ok, a, b = os.execute("sleep ".. sec)
	if not ok then error(a.." "..b) end
end


function startVm()
	local ok, a, b = os.execute("(".. shEsc(getRunFile()) ..") & printf 'vm sh pid %s\\n' $!")
	if not ok then error(a.." "..b) end
	local i = 0 while true do i = i + 1
		sleepSec(1)
		if i > 42 then error("Unable to reach VM via ssh") end
		local ok, a, b = os.execute("ssh ".. getSshHost() .." -p".. getSshPort()
			.." -oUser=".. getSshUser()
			.." -oConnectTimeout=7"
			.." -T 'true"
			..    " && mkdir -p ".. shEsc(getSshWorkdir())
			..    " && printf \"VM ssh connection OK\\n\""
			..    " && true'")
		if not ok then goto retryLater end
		break -- VM looks ready
		::retryLater::
	end
end


function stopVm()
	local ok, a, b = os.execute(asSshCmd(getSshSudo().." poweroff"))
	if not ok then error(a.." "..b) end
end


function aptInstall()
	local pkgs = { "tar", "gcc", "make", "libc-dev", "libx11-dev", "pkg-config",
		"libxft-dev", " libxcomposite-dev", "libxdamage-dev", "libxinerama-dev",
		"libjpeg62-turbo-dev", "libgif-dev", "dpkg", "lintian", }
	local cmd = "true"
		.." && aptInstall () { true"
		..    " && ".. getSshSudo() .." apt install --no-install-recommends -y"
	for _, p in ipairs(pkgs) do  cmd = cmd .." ".. p  end
	cmd = cmd
		.." ;}"
		.." && aptInstall || ".. getSshSudo() .." apt update && aptInstall"
	local ok, a, b = os.execute(asSshCmd(cmd))
	if not ok then error(a..", "..b) end
end


function cpyWorktreeIn()
	local ok, a, b = os.execute(""
		.."tar c $(ls|grep -vE '(^run$|^hda.qcow2$|^vmpid-|^tmp-)') .git"
		.." | ".. asSshCmd("tar x"))
	if not ok then error(a.." "..b) end
end


function clean()
	local ok, a, b = os.execute(asSshCmd("make clean && rm -rf skippy-xd-*"))
	if not ok then error(a.." "..b) end
end


function build()
	local ok, a, b = os.execute(asSshCmd("make"))
	if not ok then error(a.." "..b) end
end


function pkg()
	local ok, a, b = os.execute(asSshTtyCmd("true"
		--
		-- data.tar.gz
		.." && mkdir -p bin"
		.." && cp skippy-xd bin/."
		.." && strip bin/skippy-xd"
		.." && find bin -type f -exec md5sum -b {} + > MD5SUM"
		.." && tripl=\"$(gcc -dumpmachine)\""
		.." && tar --owner=0 --group=0 -Hustar -cf data.tar bin"
		.." && size=$(ls -s data.tar|cut -d' ' -f1)"
		.." && gzip -n9f data.tar"
		--
		-- control.tar.gz
		.." && cp contrib/buildvm/deb-control control"
		.." && if test \"${tripl?}\" = \"x86_64-linux-gnu\" ;then true"
		..  " && arch='amd64'"
		..  " ;else true"
		..  " && printf 'TODO: Add entry here for: %s\\n' \"${tripl:?}\" && false"
		..  " ;fi"
		.." && sed -i -E 's;^(Version: ).*$;\\1".. getVersionApprox() ..";' control"
		.." && sed -i -E 's;^(Architecture: ).*$;\\1'\"${arch:?}\"';' control"
		.." && sed -i -E 's;^(Installed-Size: ).*$;\\1'\"${size:?}\"';' control"
		.." && tar --owner=0 --group=0 -Hustar -cf control.tar control"
		.." && gzip -n9f control.tar"
		--
		-- debian-binary
		.." && printf '2.0\\n' > debian-binary"
		--
		-- deb
		.." && pkgNm=\"skippy-xd-".. getVersionApprox() .."+${tripl:?}\""
		.." && rm -rf ${pkgNm:?}.deb"
		.." && ar -rcso ${pkgNm:?}.deb debian-binary control.tar.gz data.tar.gz"
		.." && sha512sum -b ${pkgNm:?}.deb > ${pkgNm:?}.sha512"
		.." && lintian ${pkgNm:?}.deb || sleep 3"
		..""))
	if not ok then error(a.." "..b) end
end


function cpyResultOut()
	local ok, a, b = os.execute(asSshCmd("true"
		.." && tar --owner=0 --group=0 -Hustar -c"
		..      " $(ls -tr skippy-xd-*.sha512|sort|head -n1)"
		..      " $(ls -tr skippy-xd-*.deb|sort|head -n1)"
		.."").." | tar x")
	if not ok then error(a.." "..b) end
end


function main()
	createVmDisk()
	createVmRunScript()
	startVm()
	aptInstall()
	cpyWorktreeIn()
	clean()
	build()
	pkg()
	cpyResultOut()
	stopVm()
end


main()

