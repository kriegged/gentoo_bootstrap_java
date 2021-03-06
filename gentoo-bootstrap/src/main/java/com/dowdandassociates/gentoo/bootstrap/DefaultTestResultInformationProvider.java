/*
 *
 * DefaultTestResultInformationProvider.java
 *
 *-----------------------------------------------------------------------------
 * Copyright 2013 Dowd and Associates
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *-----------------------------------------------------------------------------
 *
 */

package com.dowdandassociates.gentoo.bootstrap;

import java.io.InputStream;
import java.io.OutputStream;
import java.io.IOException;

import com.google.common.base.Optional;
import com.google.common.base.Supplier;
import com.google.common.base.Suppliers;

import com.google.inject.Inject;
import com.google.inject.Provider;

import com.jcraft.jsch.ChannelExec;
import com.jcraft.jsch.JSchException;
import com.jcraft.jsch.Session;

import com.netflix.governator.annotations.Configuration;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class DefaultTestResultInformationProvider implements Provider<TestResultInformation>
{
    private static Logger log = LoggerFactory.getLogger(DefaultTestResultInformationProvider.class);

    @Configuration("com.dowdandassociates.gentoo.bootstrap.Script.sudo")
    private Supplier<String> command = Suppliers.ofInstance("uname -a");

    private TestSessionInformation sessionInfo;

    @Inject
    public DefaultTestResultInformationProvider(TestSessionInformation sessionInfo)
    {
        this.sessionInfo = sessionInfo;
    }

    public TestResultInformation get()
    {
        TestInstanceInformation instanceInfo = sessionInfo.getInstanceInfo();

        if (!sessionInfo.getSession().isPresent())
        {
            log.info("session is not present");
            Optional<Integer> exitStatus = Optional.absent();
            return new TestResultInformation().
                    withInstanceInfo(instanceInfo).
                    withExitStatus(exitStatus);
        }

        try
        {
            log.info("opening connection");
            Session session = sessionInfo.getSession().get();
            ChannelExec channel = (ChannelExec)session.openChannel("exec");

            log.info("command: " + command.get());

            log.info("setting command");
            channel.setCommand(command.get());
            channel.setPty(true);

            InputStream in = channel.getInputStream();
            OutputStream out = channel.getOutputStream();
            channel.setErrStream(System.err);

            log.info("connecting channel");
            channel.connect();

            byte[] buf = new byte[1024];


            while (true)
            {
                while (in.available() > 0)
                {
                    int i = in.read(buf, 0, 1024);
                    if (i < 0)
                    {
                        break;
                    }
                    System.out.print(new String(buf, 0, i));
                }

                if (channel.isClosed())
                {
                    log.info("exit-status: " + channel.getExitStatus());
                    break;
                }
                try
                {
                    Thread.sleep(1000);
                }
                catch (Throwable t)
                {
                }
            }

            int exitStatus = channel.getExitStatus();

            log.info("closing connection");
            channel.disconnect();
            session.disconnect();

            return new TestResultInformation().
                    withInstanceInfo(instanceInfo).
                    withExitStatus(exitStatus);
        }
        catch (IOException | JSchException e)
        {
            log.error(e.getMessage(), e);
            Optional<Integer> exitStatus = Optional.absent();
            return new TestResultInformation().
                    withInstanceInfo(instanceInfo).
                    withExitStatus(exitStatus);
        }
    }
}

