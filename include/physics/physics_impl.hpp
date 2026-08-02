#pragma once

#include "physics.hpp"
#include "actuator/actuator_impl.hpp"
#include "actuator/joint_actuator_impl.hpp"

#include <cmath>
#include <stdexcept>
#include <unordered_map>

namespace hako {
namespace robots {
namespace physics {
namespace impl {

    class RigidBodyImpl : public IRigidBody
    {
    private:
        mjModel* model;
        mjData* data;
        int body_id;
        std::unordered_map<std::string, int> joint_id_map;
        int getJointId(const std::string& joint_name) {
            auto it = joint_id_map.find(joint_name);
            if (it != joint_id_map.end()) {
                return it->second;
            }
            int id = mj_name2id(model, mjOBJ_JOINT, joint_name.c_str());
            if (id < 0) {
                throw std::runtime_error("Joint not found: " + joint_name);
            }
            joint_id_map[joint_name] = id;
            return id;
        }

        void mat2euler(const mjtNum* R, hako::robots::types::Euler& euler) {
            // R is 3x3 row-major
            euler.y = std::asin(R[6]);  // pitch = asin(R20)
        
            double cos_pitch = std::cos(euler.y);
            if (std::fabs(cos_pitch) > 1e-6) {
                euler.x = std::atan2(-R[7], R[8]);  // roll = atan2(-R21, R22)
                euler.z = std::atan2(R[3], R[0]);   // yaw = atan2(R10, R00)
            }
            else {
                // gimbal lock fallback
                euler.x = 0;
                euler.z = std::atan2(-R[1], R[4]);  // yaw fallback = atan2(-R01, R11)
            }
        }
        
        
        static hako::robots::types::Vector3 transformWorldToBody(
            const hako::robots::types::Vector3& vel,
            const hako::robots::types::Euler& angle)
        {
            double c_phi   = std::cos(angle.x), s_phi = std::sin(angle.x);
            double c_theta = std::cos(angle.y), s_theta = std::sin(angle.y);
            double c_psi   = std::cos(angle.z), s_psi = std::sin(angle.z);
    
            double x_e = vel.x;
            double y_e = vel.y;
            double z_e = vel.z;
    
            hako::robots::types::BodyVelocity body_vel;
            body_vel.x =   (c_theta * c_psi)                         * x_e
                         + (c_theta * s_psi)                         * y_e
                         - (s_theta)                                 * z_e;
    
            body_vel.y =   (s_phi * s_theta * c_psi - c_phi * s_psi) * x_e
                         + (s_phi * s_theta * s_psi + c_phi * c_psi) * y_e
                         + (s_phi * c_theta)                         * z_e;
    
            body_vel.z =   (c_phi * s_theta * c_psi + s_phi * s_psi) * x_e
                         + (c_phi * s_theta * s_psi - s_phi * c_psi) * y_e
                         + (c_phi * c_theta)                         * z_e;
    
            return body_vel;
        }
    public:
        RigidBodyImpl(mjModel* model, mjData* data, const std::string& model_name)
            : model(model), data(data)
        {
            body_id = mj_name2id(model, mjOBJ_BODY, model_name.c_str());
            if (body_id < 0) {
                throw std::runtime_error("Body not found: " + model_name);
            }
        }
        virtual ~RigidBodyImpl() override {}

        hako::robots::types::Position GetPosition() override
        {
            hako::robots::types::Position pos;
            pos.x = data->xpos[3 * body_id];
            pos.y = data->xpos[3 * body_id + 1];
            pos.z = data->xpos[3 * body_id + 2];
            return pos;
        }
        hako::robots::types::Euler GetEuler() override
        {
            hako::robots::types::Euler euler;
            const mjtNum* mat = &(data->xmat[9 * body_id]);
            mat2euler(mat, euler);
            return euler;
        }
        hako::robots::types::Velocity GetVelocity() override
        {
            mjtNum object_velocity[6] = {};
            // 【重要】mjOBJ_BODY は body の **慣性 COM** を基準点にするため、
            //   GetPosition()（= data->xpos = body 原点）の時間微分と一致しない。
            //   実測（2026-08-02）: base_link で数値微分と 0.017 m/s の差。
            //   mjOBJ_XBODY（body のレギュラーフレーム）なら 1.3e-10 で一致する。
            mj_objectVelocity(model, data, mjOBJ_XBODY, body_id, object_velocity, 0);
            hako::robots::types::Velocity vel;
            vel.x = object_velocity[3];
            vel.y = object_velocity[4];
            vel.z = object_velocity[5];
            return vel;
        }
        hako::robots::types::EulerRate GetEulerRate() override
        {
            hako::robots::types::EulerRate euler_rate = {};
            //not supported
            return euler_rate;
        }
        hako::robots::types::BodyVelocity GetBodyVelocity() override
        {
            mjtNum object_velocity[6] = {};
            // 【重要】local frame は mjOBJ_XBODY（body のレギュラーフレーム）で取る。
            //   mjOBJ_BODY は MuJoCo では **body の慣性主軸フレーム（ximat）** を指すため、
            //   body_iquat が単位でない body では「body 座標系の速度」にならない。
            //   実測（hakoniwa-humanoid H5, 2026-08-02）: base_link は
            //   body_iquat=(0.6128, 0.6131, -0.3526, 0.3526) で、MJCF <gyro>（site 座標系）と
            //   最大 1.65 rad/s ずれた。mjOBJ_XBODY にすると完全一致（差 0.000e+00）。
            mj_objectVelocity(model, data, mjOBJ_XBODY, body_id, object_velocity, 1);
            hako::robots::types::BodyVelocity body_vel;
            body_vel.x = object_velocity[3];
            body_vel.y = object_velocity[4];
            body_vel.z = object_velocity[5];
            return body_vel;
        }
        hako::robots::types::BodyAngularVelocity GetBodyAngularVelocity() override
        {
            mjtNum object_velocity[6] = {};
            // GetBodyVelocity() と同じ理由で mjOBJ_XBODY を使う（上のコメント参照）。
            mj_objectVelocity(model, data, mjOBJ_XBODY, body_id, object_velocity, 1);
            hako::robots::types::BodyAngularVelocity angular_vel;
            angular_vel.x = object_velocity[0];
            angular_vel.y = object_velocity[1];
            angular_vel.z = object_velocity[2];
            return angular_vel;
        }
        void SetTorque(const std::string& joint_name, double torque) override
        {
            int joint_id = getJointId(joint_name);
            data->ctrl[joint_id] = torque;
        }
        void SetForce(const hako::robots::types::Vector3& force) override
        {
            data->xfrc_applied[6 * body_id] = force.x;
            data->xfrc_applied[6 * body_id + 1] = force.y;
            data->xfrc_applied[6 * body_id + 2] = force.z;
        }
    };
    class WorldImpl : public IWorld
    {
    public:
        WorldImpl() {}
        virtual ~WorldImpl() {}
        void loadModel(const std::string& model_file) override
        {
            model = mj_loadXML(model_file.c_str(), nullptr, nullptr, 0);
            if (!model) {
                throw std::runtime_error("Model loading failed");
            }
            data = mj_makeData(model);
            mj_forward(model, data);
        }
        void advanceTimeStep() override
        {
            mj_step(model, data);
        }
        std::shared_ptr<IRigidBody> getRigidBody(const std::string& model_name) override
        {
            return std::make_shared<RigidBodyImpl>(model, data, model_name);
        }
        std::shared_ptr<actuator::ITorqueActuator> getTorqueActuator(const std::string& name) override {
            return std::make_shared<actuator::impl::TorqueActuatorImpl>(model, data, name);
        }
        std::shared_ptr<actuator::IJointActuator> createJointActuator() override {
            return std::make_shared<actuator::impl::JointActuatorImpl>(model, data);
        }
        
    };
}  // namespace impl
}  // namespace physics
}  // namespace robots
}  // namespace hako
